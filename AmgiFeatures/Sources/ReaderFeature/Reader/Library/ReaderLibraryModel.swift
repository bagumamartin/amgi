import AmgiReader
import AmgiReaderEPUB
import AmgiReaderPDF
import AnkiClients
import Dependencies
import Foundation

/// Data state + load/import logic for the reader Library screen. Mirrors
/// `DeckListModel`: the View owns navigation, search, sheets, and the
/// toolbar, while the model owns the EPUB/PDF/Anki book I/O, cover resolution,
/// and the engine → `ReaderLibraryContent.State` assembly so that assembly
/// is testable in isolation and the View stays thin.
@Observable
@MainActor
final class ReaderLibraryModel {
    var state: ReaderLibraryContent.State = .loading
    var importError: String?

    private(set) var books: [ReaderBook] = []
    private var bookIndex: [String: ReaderBook] = [:]
    /// Covers resolved from the two file-backed stores, keyed by book ID.
    private var localCoverURLs: [String: URL] = [:]
    /// First-page render sources for coverless EPUBs, keyed by book ID.
    /// Resolved alongside covers so the fallback costs no per-cell store I/O.
    private var localFirstPages: [String: EPUBFirstPageSource] = [:]
    /// Books that are present but unreadable. Kept so the row can render a
    /// repair affordance instead of the book silently vanishing.
    ///
    /// One map for both formats, keyed by book ID, because a row cannot tell the
    /// two stores apart — an EPUB and a PDF break the same way and are repaired
    /// the same way. Which store to call is decided from the book itself.
    private var repairs: [String: ReaderBookRepair] = [:]
    /// Saved-progress snapshot taken during `reload` so the synchronous
    /// `rebuildViewData` (search/sort onChange) never awaits the engine.
    private var progressByBook: [String: ReaderSavedProgress] = [:]

    @ObservationIgnored @Dependency(\.readerBookClient) private var readerBookClient
    @ObservationIgnored @Dependency(\.epubLibraryClient) private var epubLibraryClient
    @ObservationIgnored @Dependency(\.pdfLibraryClient) private var pdfLibraryClient
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// Shared with `ReaderLibraryContent` so the list and the loader resolve
    /// saved progress through the same store.
    let progress: ReaderProgressCoordinator

    init(progress: ReaderProgressCoordinator = ReaderProgressCoordinator()) {
        self.progress = progress
    }

    func book(for id: String) -> ReaderBook? { bookIndex[id] }

    var hasAnkiConfiguration: Bool {
        ReaderConfigurationLoader.loadConfiguration() != nil
    }

    func startReload(searchText: String, sortMode: BookshelfSortMode) {
        reloadTask?.cancel()
        reloadTask = Task { await reload(searchText: searchText, sortMode: sortMode) }
    }

    func reload(searchText: String, sortMode: BookshelfSortMode) async {
        if books.isEmpty { state = .loading }

        // Retry any collection-side progress write that was lost to a
        // backgrounding or force-quit after a chapter closed.
        await progress.flushPendingPushes()

        // Both file-backed stores are asked at once rather than in sequence.
        // They are independent — separate directories, separate indexes — so
        // awaiting one before starting the other doubles the time the library
        // takes to appear on a cold launch for no reason.
        async let epubBooks: [ReaderBook] = epubLibraryClient.listBooks()
        async let pdfBooks: [ReaderBook] = pdfLibraryClient.listBooks()

        var ankiBooks: [ReaderBook] = []
        var firstError: String?
        if let configuration = ReaderConfigurationLoader.loadConfiguration() {
            do {
                ankiBooks = try await readerBookClient.loadBooks(configuration)
            } catch {
                firstError = error.localizedDescription
            }
        }

        let resolvedEPUBs = await epubBooks
        let resolvedPDFs = await pdfBooks
        if Task.isCancelled { return }
        // The two stores cannot collide on book ID: each derives one from the
        // document's own identity and prefixes it, so an EPUB and a PDF are
        // never the same entry.
        let merged = ankiBooks + resolvedEPUBs + resolvedPDFs
        books = merged
        bookIndex = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Covers come from whichever store owns the book. Dispatching on the
        // book's own source, rather than on which list it came from, is what
        // keeps this correct as formats are added.
        var resolved: [String: URL] = [:]
        let epubClient = epubLibraryClient
        let pdfClient = pdfLibraryClient
        await withTaskGroup(of: (String, URL?).self) { group in
            for book in merged {
                switch book.source {
                case .epub:
                    group.addTask { (book.id, await epubClient.coverURL(book.id)) }
                case .pdf:
                    group.addTask { (book.id, await pdfClient.coverURL(book.id)) }
                case .ankiDeck:
                    break
                }
            }
            for await (id, url) in group {
                if let url { resolved[id] = url }
            }
        }
        if Task.isCancelled { return }
        localCoverURLs = resolved

        // EPUBs without embedded cover art fall back in two stages: first a
        // cover image lifted from the first chapter (which usually *is* the
        // cover), then a first-page render. Resolve both here, once per
        // reload, so cells never hit the store or the filesystem per body
        // pass. Only coverless EPUBs pay for the extra lookups.
        var firstPages: [String: EPUBFirstPageSource] = [:]
        await withTaskGroup(of: (String, URL?, EPUBFirstPageSource?).self) { group in
            for book in merged {
                guard case .epub = book.source,
                      resolved[book.id] == nil,
                      let firstChapter = book.chapters.first else { continue }
                group.addTask {
                    guard let readAccess = await epubClient.contentRootURL(book.id),
                          let content = await epubClient.chapterContentURL(book.id, firstChapter.id) else {
                        return (book.id, nil, nil)
                    }
                    // Pure file work off the main actor: SAX scan plus image
                    // header reads, no WebKit, no store access.
                    if let image = await Task.detached(priority: .utility, operation: {
                        EPUBCoverImageExtractor.firstCoverImageURL(
                            chapterURL: content,
                            contentRootURL: readAccess
                        )
                    }).value {
                        return (book.id, image, nil)
                    }
                    return (book.id, nil, EPUBFirstPageSource(contentURL: content, readAccessURL: readAccess))
                }
            }
            for await (id, cover, firstPage) in group {
                if let cover { resolved[id] = cover }
                if let firstPage { firstPages[id] = firstPage }
            }
        }
        if Task.isCancelled { return }
        localFirstPages = firstPages

        // Ask the stores which books need repair. This is the authoritative
        // check, so a book whose source vanished since the last launch is
        // flagged here instead of quietly dropping out of the list.
        let epubHealth = await epubLibraryClient.bookHealth()
        let pdfHealth = await pdfLibraryClient.bookHealth()
        var foundRepairs: [String: ReaderBookRepair] = [:]
        for (id, state) in epubHealth {
            if case .needsRepair(let fault, let detail) = state.state {
                foundRepairs[id] = ReaderBookRepair(fault: fault, detail: detail)
            }
        }
        for (id, state) in pdfHealth {
            if case .needsRepair(let fault, let detail) = state.state {
                foundRepairs[id] = ReaderBookRepair(fault: fault, detail: detail)
            }
        }
        if Task.isCancelled { return }
        repairs = foundRepairs

        var progressSnapshot: [String: ReaderSavedProgress] = [:]
        for book in merged {
            if let saved = await progress.resolved(bookID: book.id) {
                progressSnapshot[book.id] = saved
            }
        }
        if Task.isCancelled { return }
        progressByBook = progressSnapshot

        if merged.isEmpty {
            if let firstError {
                state = .error(firstError)
            } else if hasAnkiConfiguration {
                state = .empty(.noBooksConfigured)
            } else {
                state = .empty(.noBooksAndNoConfig)
            }
            return
        }

        rebuildViewData(searchText: searchText, sortMode: sortMode)
    }

    func rebuildViewData(searchText: String, sortMode: BookshelfSortMode) {
        guard !books.isEmpty else { return }
        let coverURLs = localCoverURLs
        let firstPages = localFirstPages
        let repairSnapshot = repairs
        let data = ReaderLibraryViewDataBuilder.build(
            books: books,
            progressFor: { [progressByBook] in progressByBook[$0] },
            epubCoverURLFor: { coverURLs[$0] },
            epubFirstPageFor: { firstPages[$0] },
            repairFor: { repairSnapshot[$0] },
            searchText: searchText,
            sortMode: sortMode,
            hasAnkiConfig: hasAnkiConfiguration
        )
        state = .loaded(data)
    }

    /// Re-read one book in place. Returns true when it became readable again.
    @discardableResult
    func retryRepair(bookID: String) async -> Bool {
        // Dispatched on the book's own source. Guessing from the fault, or
        // calling both stores, would either repair the wrong library or do the
        // work twice; the book knows where it lives.
        let repaired: ReaderBook?
        switch book(for: bookID)?.source {
        case .pdf:
            repaired = await pdfLibraryClient.retryBook(bookID)
        default:
            repaired = await epubLibraryClient.retryBook(bookID)
        }
        if repaired == nil { return false }
        await reloadRepairState()
        return true
    }

    /// Point a broken book at a replacement file on disk.
    func relink(bookID: String, to url: URL) async throws {
        switch book(for: bookID)?.source {
        case .pdf:
            _ = try await pdfLibraryClient.relinkBook(bookID, url)
        default:
            _ = try await epubLibraryClient.relinkBook(bookID, url)
        }
        await reloadRepairState()
    }

    /// Refresh only the health state after a repair, then rebuild the visible
    /// rows. Avoids a full reload so the list does not flash.
    private func reloadRepairState() async {
        let epubHealth = await epubLibraryClient.bookHealth()
        let pdfHealth = await pdfLibraryClient.bookHealth()
        var found: [String: ReaderBookRepair] = [:]
        for (id, state) in epubHealth {
            if case .needsRepair(let fault, let detail) = state.state {
                found[id] = ReaderBookRepair(fault: fault, detail: detail)
            }
        }
        for (id, state) in pdfHealth {
            if case .needsRepair(let fault, let detail) = state.state {
                found[id] = ReaderBookRepair(fault: fault, detail: detail)
            }
        }
        repairs = found
    }

    /// Imports book files, routing each to the store that owns its format.
    ///
    /// One entry point rather than one per format, because the picker hands
    /// over a mixed selection and the user should not have to choose which
    /// button to press. A file whose extension is not recognised is reported
    /// rather than skipped silently — an import that appears to do nothing is
    /// indistinguishable from a broken one.
    func importBooks(_ urls: [URL], searchText: String, sortMode: BookshelfSortMode) async {
        var succeeded = 0
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                switch url.pathExtension.lowercased() {
                case "pdf":
                    _ = try await pdfLibraryClient.importPDF(url)
                case "epub":
                    _ = try await epubLibraryClient.importEPUB(url)
                default:
                    importError = "\"\(url.lastPathComponent)\" is not an EPUB or a PDF."
                    continue
                }
                succeeded += 1
            } catch {
                importError = error.localizedDescription
            }
        }
        if succeeded > 0 {
            startReload(searchText: searchText, sortMode: sortMode)
        }
    }
}
