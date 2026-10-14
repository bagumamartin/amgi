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
@MainActor @Observable
package final class CollectionRetrievalCoordinator {
    package static let shared = CollectionRetrievalCoordinator()
    package private(set) var completed = 0
    package private(set) var total = 0
    package private(set) var isIndexing = false
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
    package func pause() { UserDefaults.standard.set(true, forKey: pauseKey); cancel() }
    package func resume() { UserDefaults.standard.removeObject(forKey: pauseKey); refresh() }
    package func cancel() { task?.cancel(); task = nil; jobID = nil; index = nil; profile = nil; needsRescan = false; isIndexing = false }
    package func search(_ query: String, limit: Int = 12) async throws -> [RetrievalHit] {
        let index = try resolve(), context = AccountStore.shared.selectedContext
        let vector = try? await TextEmbedder.shared.embed(query, prefix: .query)
        guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
        return try await index.search(query, vector: vector, limit: limit)
    }
    private func read<T>(_ context: ProfileContext, _ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard context.isCurrent(AccountStore.shared.selectedContext), ReviewSessionActivity.shared.beginExternalRead() else { throw CancellationError() }
        defer { ReviewSessionActivity.shared.endRead() }
        let value = try await body()
        guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
        return value
    }
    private func scan(index: RetrievalIndex, context: ProfileContext) async {
        isIndexing = true; completed = 0; total = 0; failures = []
        defer { if context.isCurrent(AccountStore.shared.selectedContext) { isIndexing = false } }
        let cache = AccountStore.profileDirectory(for: AccountStore.shared.current.id).appendingPathComponent("RetrievalPreviews", isDirectory: true)
        let worker = MediaIndexer(index: index, cache: cache)
        do {
            let ids = try await read(context) { try await notes.searchIds("", nil) }
            let deckList = try await read(context) { try await decks.fetchAll() }
            let deckNames = Dictionary(uniqueKeysWithValues: deckList.map { ($0.id, $0.name) })
            total = ids.count
            var sources = Set<String>()
            for id in ids {
                try Task.checkCancellation()
                guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
                let source = "note:\(id.rawValue)"; sources.insert(source)
                guard let note = try await read(context, { try await notes.fetch(id) }) else { continue }
                let noteCards = try await read(context) { try await cards.fetchByNote(id) }
                let names = Set(noteCards.compactMap { deckNames[$0.did] }).sorted().joined(separator: ", ")
                let text = CardText.plainText(note.flds.replacingOccurrences(of: "\u{1f}", with: "\n")) + "\nTags: \(note.tags)\nDecks: \(names)"
                let hash = Self.hash(text)
                var segments = Set<String>()
                for (offset, passage) in MediaIndexer.passages(text).enumerated() {
                    let segment = source + ":passage:\(offset)"; segments.insert(segment)
                    try await worker.indexText(passage, id: segment, sourceID: source, title: String(CardText.plainText(note.sfld).prefix(160)), anchor: "note:\(id.rawValue):passage:\(offset)", fingerprint: hash)
                }
                try await index.pruneSource(source, keeping: segments)
                completed += 1
            }
            try await index.pruneSources(prefix: "note:", keeping: sources)
            // Anki's managed media directory, never arbitrary filesystem roots.
            if let root = try await read(context, { media.folderURL() }) {
                let owned = Self.ownedFiles(in: root)
                total += owned.count
                var mediaSources = Set<String>()
                for url in owned {
                    try Task.checkCancellation(); guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
                    let source = "media:\(url.path.replacingOccurrences(of: root.path + "/", with: ""))"; mediaSources.insert(source)
                    do { try await worker.indexFile(url, sourceID: source, title: url.lastPathComponent) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    completed += 1
                }
                try await index.pruneSources(prefix: "media:", keeping: mediaSources)
            }
            let books = try await read(context) { await epub.listBooks() + pdf.listBooks() }
            total += books.count
            var bookSources = Set<String>()
            for book in books {
                try Task.checkCancellation(); guard context.isCurrent(AccountStore.shared.selectedContext) else { throw CancellationError() }
                let source = "book:\(book.id)"; bookSources.insert(source)
                do {
                    switch book.source {
                    case .pdf(let url): try await worker.indexFile(url, sourceID: source, title: book.title)
                    case .epub:
                        var segments = Set<String>()
                        for chapter in book.chapters {
                            let contentURL = await epub.chapterContentURL(book.id, chapter.id)
                            let raw = contentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? chapter.content
                            let text = CardText.plainText(raw), hash = Self.hash(raw)
                            for (offset, passage) in MediaIndexer.passages(text).enumerated() {
                                let id = source + ":chapter:\(chapter.id):passage:\(offset)"; segments.insert(id)
                                try await worker.indexText(passage, id: id, sourceID: source, title: book.title, anchor: "chapter:\(chapter.id):passage:\(offset)", url: contentURL, fingerprint: hash)
                            }
                        }
                        try await index.pruneSource(source, keeping: segments)
                    case .ankiDeck: break // covered by the full note corpus
                    }
                    let annotationStore = ReaderAnnotationStore(libraryRoot: AccountStore.profileDirectory(for: AccountStore.shared.current.id).appendingPathComponent("EPUB"))
                    let annotations = try await annotationStore.annotations(inBook: book.id)
                    for annotation in annotations {
                        bookSources.insert(source + ":annotation:\(annotation.id)")
                        let text = annotation.excerpt + "\n" + (annotation.note ?? "")
                        try await worker.indexText(text, id: "annotation:\(annotation.id)", sourceID: source + ":annotation:\(annotation.id)", title: book.title, anchor: String(describing: annotation.anchor), fingerprint: Self.hash(text))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("\(book.title): \(error.localizedDescription)") }
                completed += 1
            }
            try await index.pruneSources(prefix: "book:", keeping: bookSources)
            failures += await worker.failures
        } catch is CancellationError { }
        catch { failures.append(error.localizedDescription) }
    }
    private static func ownedFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { urls.append(url) }
        return urls
    }
    private static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
