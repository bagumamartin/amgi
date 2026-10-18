import AmgiAppCore
import AmgiCardWeb
public import AmgiEmbeddings
import AmgiReader
import AmgiReviewCore
import AnkiClients
import AnkiKit
import CryptoKit
import Dependencies
import Foundation
import Observation

/// One incremental indexing job per active profile, independent of Browse's
/// paged results. Only collection media and managed reader books are visited.
///
/// Every scan walks the whole profile, but cheaply: each indexed source keeps
/// a change fingerprint in the index (a note's mtime, a file's size and date,
/// plus which model modules were installed), so an unchanged source costs a
/// dictionary lookup — no text extraction, hashing or embedding. Notes are
/// read 400 at a time and their changed passages embedded in batches.
///
/// Known staleness, accepted: a note's indexed text names its decks, and
/// moving a card between decks does not touch the note's mtime, so the deck
/// names refresh on the note's next edit. Deck-scoped search asks the engine
/// for the deck's notes instead of trusting that text.
@MainActor @Observable
package final class CollectionRetrievalCoordinator {
    package enum Phase: Equatable { case idle, checking, indexing }
    package static let shared = CollectionRetrievalCoordinator()
    package private(set) var phase: Phase = .idle
    /// Changed sources handled so far, of `total` changed sources found.
    package private(set) var completed = 0
    package private(set) var total = 0
    package var isIndexing: Bool { phase != .idle }
    /// Sources searchable after the last finished scan.
    package private(set) var indexedSources: Int?
    package private(set) var failures: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var profile: ProfileContext?
    @ObservationIgnored private var index: RetrievalIndex?
    @ObservationIgnored private var jobID: UUID?
    @ObservationIgnored private var needsRescan = false
    @ObservationIgnored @Dependency(\.noteClient) private var notes
    @ObservationIgnored @Dependency(\.cardClient) private var cards
    @ObservationIgnored @Dependency(\.deckClient) private var decks
    @ObservationIgnored @Dependency(\.mediaClient) private var media
    @ObservationIgnored @Dependency(\.epubLibraryClient) private var epub
    @ObservationIgnored @Dependency(\.pdfLibraryClient) private var pdf

    private func resolve() throws -> RetrievalIndex {
        let context = AccountStore.shared.selectedContext
        if profile?.isCurrent(context) != true {
            task?.cancel(); task = nil; jobID = nil; needsRescan = false
            profile = context
            indexedSources = nil
            let directory = AccountStore.profileDirectory(for: AccountStore.shared.current.id)
            index = try RetrievalIndex(url: directory.appendingPathComponent("retrieval-\(context.id).sqlite"))
        }
        return index!
    }
    package func refresh() {
        guard ModelAssetManager.isModelInstalled, !UserDefaults.standard.bool(forKey: pauseKey) else { return }
        do {
            let index = try resolve()
            guard task == nil else { needsRescan = true; return }
            let context = AccountStore.shared.selectedContext
            let id = UUID(); jobID = id
            task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.scan(index: index, context: context)
                guard self.jobID == id else { return }
                self.task = nil; self.jobID = nil
                if self.needsRescan { self.needsRescan = false; self.refresh() }
            }
        } catch { failures = [error.localizedDescription] }
    }
    private var pauseKey: String { "retrieval.paused.\(AccountStore.shared.selectedContext.id)" }
    package var isPaused: Bool { UserDefaults.standard.bool(forKey: pauseKey) }
    package func pause() { UserDefaults.standard.set(true, forKey: pauseKey); cancel() }
    package func resume() { UserDefaults.standard.removeObject(forKey: pauseKey); refresh() }
    package func cancel() { task?.cancel(); task = nil; jobID = nil; index = nil; profile = nil; needsRescan = false; phase = .idle }

    // MARK: Queries

    package static func noteSource(_ id: Int64) -> String { "note:\(id)" }
    package static func bookSource(_ id: String) -> String { "book:\(id)" }
    package static func noteID(of source: String) -> Int64? {
        source.hasPrefix("note:") ? Int64(source.dropFirst(5)) : nil
    }

    package func search(_ query: String, limit: Int = 12, filter: RetrievalFilter = .all, groupBySource: Bool = true, lexical: Bool = true) async throws -> [RetrievalHit] {
        let index = try resolve(), context = AccountStore.shared.selectedContext
        let vector = try? await TextEmbedder.shared.embed(query, prefix: .query)
        guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
        return try await index.search(query, vector: vector, limit: limit, filter: filter, groupBySource: groupBySource, lexical: lexical)
    }

    /// Notes and passages closest in meaning to a note.
    package func related(toNote id: Int64, limit: Int = 8, filter: RetrievalFilter = .all) async throws -> [RetrievalHit] {
        try await resolve().neighbors(of: Self.noteSource(id), limit: limit, filter: filter)
    }

    /// The passages `target` admits that no note resembles, least covered first.
    package func uncovered(_ target: RetrievalFilter, limit: Int = 6) async throws -> [RetrievalCoverage] {
        try await resolve().coverage(of: target, against: RetrievalFilter(sourcePrefixes: ["note:"]), limit: limit)
    }

    /// The note's pooled vector from the index when it was indexed at this
    /// exact mtime, so Browse's duplicate check needn't embed it again.
    package func indexedNoteVector(_ id: Int64, mod: Int64) async -> [Float]? {
        guard let index = try? resolve() else { return nil }
        return try? await index.pooledVector(source: Self.noteSource(id), fingerprint: Self.noteFingerprint(mod: mod))
    }

    // MARK: Scanning

    private static var textTag: String { ModelAssetManager.isModelInstalled ? "t1" : "t0" }
    private static var mediaTag: String {
        textTag + (ModelAssetManager.isInstalled(.vision) ? "v1" : "v0") + (ModelAssetManager.isInstalled(.audio) ? "a1" : "a0")
    }
    private static func noteFingerprint(mod: Int64) -> String { "\(mod)|\(textTag)" }

    private func read<T>(_ context: ProfileContext, _ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard context.isCurrent(AccountStore.shared.selectedContext), ReviewSessionActivity.shared.beginExternalRead() else { throw CancellationError() }
        defer { ReviewSessionActivity.shared.endRead() }
        let value = try await body()
        guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
        return value
    }
    private func checkCurrent(_ context: ProfileContext) throws {
        try Task.checkCancellation()
        guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
    }
    private func found(_ changed: Int) {
        guard changed > 0 else { return }
        total += changed
        phase = .indexing
    }

    private func scan(index: RetrievalIndex, context: ProfileContext) async {
        phase = .checking; completed = 0; total = 0; failures = []
        let cache = AccountStore.profileDirectory(for: AccountStore.shared.current.id).appendingPathComponent("RetrievalPreviews", isDirectory: true)
        // Previews are deleted after each page or frame; anything still here
        // is a leftover from an interrupted write.
        try? FileManager.default.removeItem(at: cache)
        let worker = MediaIndexer(index: index, cache: cache)
        do {
            try await scanNotes(index: index, worker: worker, context: context)
            try await scanMedia(index: index, worker: worker, context: context)
            try await scanBooks(index: index, worker: worker, context: context)
            failures += await worker.failures
        } catch is CancellationError { }
        catch { failures.append(error.localizedDescription) }
        guard context.isCurrent(AccountStore.shared.selectedContext) else { return }
        phase = .idle
        indexedSources = try? await index.sourceCount()
    }

    private func scanNotes(index: RetrievalIndex, worker: MediaIndexer, context: ProfileContext) async throws {
        let ids = try await read(context) { try await notes.searchIds("", nil) }
        let known = try await index.sourceFingerprints(prefix: "note:")
        let sources = Set(ids.map { Self.noteSource($0.rawValue) })
        var deckNames: [DeckID: String]?
        for start in stride(from: 0, to: ids.count, by: 400) {
            try checkCurrent(context)
            let chunk = ids[start..<min(ids.count, start + 400)]
            // Fingerprints first: an id we already hold at this mtime is
            // skipped without fetching anything else.
            let query = "nid:" + chunk.map { String($0.rawValue) }.joined(separator: ",")
            let records = try await read(context) { try await notes.searchAll(query, nil) }
            let changed = records.filter { known[Self.noteSource($0.id.rawValue)] != Self.noteFingerprint(mod: $0.mod) }
            guard !changed.isEmpty else { continue }
            found(changed.count)
            if deckNames == nil {
                let list = try await read(context) { try await decks.fetchAll() }
                deckNames = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
            var items: [MediaIndexer.TextItem] = []
            var kept: [String: Set<String>] = [:]
            for record in changed {
                let noteCards = try await read(context) { try await cards.fetchByNote(record.id) }
                let names = Set(noteCards.compactMap { deckNames?[$0.did] }).sorted().joined(separator: ", ")
                let source = Self.noteSource(record.id.rawValue)
                let noteItems = await Self.noteItems(record, decks: names, source: source)
                kept[source] = Set(noteItems.map(\.id))
                items += noteItems
            }
            let failed = try await worker.indexTexts(items)
            var recorded: [String: String] = [:]
            for record in changed {
                let source = Self.noteSource(record.id.rawValue)
                try await index.pruneSource(source, keeping: kept[source] ?? [])
                if !failed.contains(source) { recorded[source] = Self.noteFingerprint(mod: record.mod) }
            }
            try await index.recordSources(recorded)
            completed += changed.count
        }
        try await index.pruneSources(prefix: "note:", keeping: sources)
    }

    /// Off the main actor: HTML stripping and hashing a few thousand notes
    /// is real work.
    @concurrent nonisolated private static func noteItems(_ note: NoteRecord, decks: String, source: String) async -> [MediaIndexer.TextItem] {
        let text = CardText.plainText(note.flds.replacingOccurrences(of: "\u{1f}", with: "\n")) + "\nTags: \(note.tags)\nDecks: \(decks)"
        let hash = Self.hash(text)
        let title = String(CardText.plainText(note.sfld).prefix(160))
        return MediaIndexer.passages(text).enumerated().map { offset, passage in
            MediaIndexer.TextItem(text: passage, id: source + ":passage:\(offset)", sourceID: source, title: title, anchor: "note:\(note.id.rawValue):passage:\(offset)", fingerprint: hash)
        }
    }

    private func scanMedia(index: RetrievalIndex, worker: MediaIndexer, context: ProfileContext) async throws {
        // Anki's managed media directory, never arbitrary filesystem roots.
        guard let root = try await read(context, { media.folderURL() }) else { return }
        let owned = await Self.ownedFiles(in: root)
        let known = try await index.sourceFingerprints(prefix: "media:")
        let tag = Self.mediaTag
        var sources = Set<String>()
        var changed: [(URL, String, String)] = []
        for (url, stamp) in owned {
            let source = "media:\(url.path.replacingOccurrences(of: root.path + "/", with: ""))"
            sources.insert(source)
            let fingerprint = stamp + "|" + tag
            if known[source] != fingerprint { changed.append((url, source, fingerprint)) }
        }
        found(changed.count)
        for (url, source, fingerprint) in changed {
            try checkCurrent(context)
            do {
                if try await worker.indexFile(url, sourceID: source, title: url.lastPathComponent) {
                    try await index.recordSource(source, fingerprint: fingerprint)
                }
            }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            completed += 1
        }
        try await index.pruneSources(prefix: "media:", keeping: sources)
    }

    private func scanBooks(index: RetrievalIndex, worker: MediaIndexer, context: ProfileContext) async throws {
        let books = try await read(context) { await epub.listBooks() + pdf.listBooks() }
        let known = try await index.sourceFingerprints(prefix: "book:")
        let annotationStore = ReaderAnnotationStore(libraryRoot: AccountStore.profileDirectory(for: AccountStore.shared.current.id).appendingPathComponent("EPUB"))
        var sources = Set<String>()
        for book in books {
            try checkCurrent(context)
            let source = Self.bookSource(book.id); sources.insert(source)
            do {
                let fingerprint: String? = switch book.source {
                case .pdf(let url): Self.stamp(url).map { $0 + "|" + Self.mediaTag }
                case .epub(let url):
                    (Self.stamp(url) ?? "") + "|\(book.chapters.count)|\(book.chapters.reduce(0) { $0 + $1.content.utf8.count })|" + Self.textTag
                case .ankiDeck: nil // covered by the full note corpus
                }
                if let fingerprint, known[source] != fingerprint {
                    found(1)
                    var complete = true
                    switch book.source {
                    case .pdf(let url): complete = try await worker.indexFile(url, sourceID: source, title: book.title)
                    case .epub:
                        var items: [MediaIndexer.TextItem] = []
                        for chapter in book.chapters {
                            let contentURL = await epub.chapterContentURL(book.id, chapter.id)
                            items += await Self.chapterItems(chapter, contentURL: contentURL, source: source, title: book.title)
                        }
                        complete = try await worker.indexTexts(items).isEmpty
                        try await index.pruneSource(source, keeping: Set(items.map(\.id)))
                    case .ankiDeck: break
                    }
                    if complete { try await index.recordSource(source, fingerprint: fingerprint) }
                    completed += 1
                }
                var annotations: [MediaIndexer.TextItem] = []
                var stamps: [String: String] = [:]
                for annotation in try await annotationStore.annotations(inBook: book.id) {
                    let annotationSource = source + ":annotation:\(annotation.id)"
                    sources.insert(annotationSource)
                    let text = annotation.excerpt + "\n" + (annotation.note ?? "")
                    let hash = Self.hash(text)
                    guard known[annotationSource] != hash + "|" + Self.textTag else { continue }
                    stamps[annotationSource] = hash + "|" + Self.textTag
                    annotations.append(.init(text: text, id: "annotation:\(annotation.id)", sourceID: annotationSource, title: book.title, anchor: String(describing: annotation.anchor), fingerprint: hash))
                }
                if !annotations.isEmpty {
                    let failed = try await worker.indexTexts(annotations)
                    try await index.recordSources(stamps.filter { !failed.contains($0.key) })
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(book.title): \(error.localizedDescription)") }
        }
        try await index.pruneSources(prefix: "book:", keeping: sources)
    }

    @concurrent nonisolated private static func chapterItems(_ chapter: ReaderChapter, contentURL: URL?, source: String, title: String) async -> [MediaIndexer.TextItem] {
        let raw = contentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? chapter.content
        let text = CardText.plainText(raw), hash = Self.hash(raw)
        return MediaIndexer.passages(text).enumerated().map { offset, passage in
            MediaIndexer.TextItem(text: passage, id: source + ":chapter:\(chapter.id):passage:\(offset)", sourceID: source, title: title, anchor: "chapter:\(chapter.id):passage:\(offset)", url: contentURL, fingerprint: hash)
        }
    }

    /// Each regular file with a size-and-date stamp. Stat only — the content
    /// hash is taken by the indexer, and only for files whose stamp changed.
    @concurrent nonisolated private static func ownedFiles(in root: URL) async -> [(URL, String)] { listFiles(in: root) }
    private nonisolated static func listFiles(in root: URL) -> [(URL, String)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, "\(values.fileSize ?? 0)@\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"))
        }
        return files
    }
    private nonisolated static func stamp(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return "\(values.fileSize ?? 0)@\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    private nonisolated static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
