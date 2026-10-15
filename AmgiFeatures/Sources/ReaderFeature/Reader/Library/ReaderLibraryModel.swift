import AmgiAppCore
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
    /// A book action (rename, remove) that failed, for an alert.
    var actionError: String?
    /// Files being imported right now, shown as placeholder tiles at the top
    /// of the grid from the moment they are picked until the book is in.
    private(set) var pendingImports: [PendingImport] = []
    /// When each book was imported, this session. Puts a new book at the
    /// front of the "Recently Read" order straight away.
    @ObservationIgnored private var importedAt: [String: Date] = [:]
    /// Books removed from Continue, and when. Profile-scoped like progress.
    private var continueHidden: [String: Date] = ReaderLibraryModel.loadContinueHidden()
    /// True while the Library's own sync button is working.
    private(set) var isSyncingLibrary = false
    var isImportingBooks: Bool = false

    private(set) var books: [ReaderBook] = []
    /// The library's folders. Loaded once per model; every edit is written
    /// straight back, so it never waits on a reload.
    private(set) var collections: ReaderCollectionTree
    /// Every book as a grid cell in display order, ignoring the search, for
    /// the collection screens (which do not search) and collage covers.
    private(set) var sortedCells: [BookCellItem] = []
    @ObservationIgnored private let collectionStore: ReaderCollectionStore
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
    @ObservationIgnored @Dependency(\.readerCollectionSyncClient) private var collectionSync
    @ObservationIgnored private var collectionSyncTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// iCloud work that follows a reload: flushing pending progress pushes,
    /// then merging newer positions from other devices. Kept off `reload` so
    /// the library (and pull-to-refresh) never waits on the network.
    @ObservationIgnored private var cloudProgressTask: Task<Void, Never>?
    /// The query the visible rows were last built for, so the late iCloud
    /// merge rebuilds for whatever the user is looking at by then.
    @ObservationIgnored private var lastQuery: (searchText: String, sortMode: BookshelfSortMode)?

    /// Shared with `ReaderLibraryContent` so the list and the loader resolve
    /// saved progress through the same store.
    let progress: ReaderProgressCoordinator

    init(
        progress: ReaderProgressCoordinator = ReaderProgressCoordinator(),
        collectionStore: ReaderCollectionStore = .forCurrentProfile()
    ) {
        self.progress = progress
        self.collectionStore = collectionStore
        self.collections = collectionStore.load()
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
        // Published only now: the pass above adds covers lifted from first
        // chapters to `resolved`. Assigning before it dropped every one of
        // them, leaving those books on the generic tile.
        localCoverURLs = resolved
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

        // Local positions only. Everything above is on-device too, so the
        // library appears at the same speed with or without a network.
        progressByBook = progress.localAll(bookIDs: merged.map(\.id))
        startCloudProgressMerge(bookIDs: merged.map(\.id))
        syncCollections(pullFirst: true)

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

    /// Pushes any reading positions that never reached iCloud, then folds in
    /// newer positions from other devices and rebuilds the rows if anything
    /// changed. Best effort: offline, both steps give up and the library keeps
    /// showing local positions.
    private func startCloudProgressMerge(bookIDs: [String]) {
        cloudProgressTask?.cancel()
        let progress = progress
        cloudProgressTask = Task { [weak self] in
            // Retry any progress write that was lost to a backgrounding or
            // force-quit after a chapter closed.
            await progress.flushPendingPushes()
            let resolved = await progress.resolveAll(bookIDs: bookIDs)
            guard !Task.isCancelled, let self, resolved != self.progressByBook else { return }
            self.progressByBook = resolved
            if let query = self.lastQuery {
                self.rebuildViewData(searchText: query.searchText, sortMode: query.sortMode)
            }
        }
    }

    func rebuildViewData(searchText: String, sortMode: BookshelfSortMode) {
        guard !books.isEmpty else { return }
        lastQuery = (searchText, sortMode)
        let coverURLs = localCoverURLs
        let firstPages = localFirstPages
        let repairSnapshot = repairs
        func build(_ query: String) -> ReaderLibraryViewData {
            ReaderLibraryViewDataBuilder.build(
                books: books,
                progressFor: { [progressByBook] in progressByBook[$0] },
                epubCoverURLFor: { coverURLs[$0] },
                epubFirstPageFor: { firstPages[$0] },
                repairFor: { repairSnapshot[$0] },
                addedAt: { [importedAt] in importedAt[$0] },
                continueHiddenAt: { [continueHidden] in continueHidden[$0] },
                searchText: query,
                sortMode: sortMode,
                hasAnkiConfig: hasAnkiConfiguration,
                collections: collections
            )
        }
        let data = build(searchText)
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sortedCells = searching ? build("").allBooks : data.allBooks
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
    ///
    /// Each imported book is optimistically inserted into the bookshelf immediately
    /// so the user sees it appear in real time without waiting for full library
    /// health checks or sync reloads to complete.
    func importBooks(_ urls: [URL], searchText: String, sortMode: BookshelfSortMode) async {
        isImportingBooks = true
        defer { isImportingBooks = false }

        // Imports are quick (a large PDF in well under a second), so most
        // books simply appear. A placeholder tile shows only for one still
        // going after a moment — a big EPUB, or a file iCloud is still
        // downloading — rather than flashing for every import.
        let pending = urls.map(PendingImport.init(url:))
        let placeholderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.pendingImports.append(contentsOf: pending)
            // An empty library shows "No books yet" rather than a grid,
            // which would hide the placeholder of its very first book.
            if case .empty = self.state {
                self.state = .loaded(ReaderLibraryViewData(
                    continueReading: [],
                    allBooks: [],
                    hasAnkiConfig: self.hasAnkiConfiguration
                ))
            }
        }
        defer {
            placeholderTask.cancel()
            let finished = Set(pending.map(\.id))
            pendingImports.removeAll { finished.contains($0.id) }
        }

        var succeeded = 0
        for (url, placeholder) in zip(urls, pending) {
            defer { pendingImports.removeAll { $0.id == placeholder.id } }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let importedBook: ReaderBook
                switch url.pathExtension.lowercased() {
                case "pdf":
                    importedBook = try await pdfLibraryClient.importPDF(url)
                case "epub":
                    importedBook = try await epubLibraryClient.importEPUB(url)
                default:
                    importError = "\"\(url.lastPathComponent)\" is not an EPUB or a PDF."
                    continue
                }
                importedAt[importedBook.id] = .now
                await upsertImportedBook(importedBook, searchText: searchText, sortMode: sortMode)
                succeeded += 1
            } catch {
                importError = error.localizedDescription
            }
        }
        if succeeded > 0 {
            startReload(searchText: searchText, sortMode: sortMode)
        }
    }

    // MARK: - Collections

    /// The grid inside one collection. Collection screens do not search, so
    /// this always works from the unfiltered cells.
    func gridItems(in collectionID: String) -> [LibraryGridItem] {
        ReaderLibraryViewDataBuilder.grid(cells: sortedCells, collections: collections, in: collectionID)
    }

    func collection(_ id: String) -> ReaderCollection? { collections.collection(id) }

    func canMove(_ items: [ReaderLibraryItemRef], to destination: String?) -> Bool {
        items.contains { item in
            item != .collection(destination ?? "") && collections.canMove(item, to: destination)
                && collections.parent(of: item) != destination
        }
    }

    /// Moves every item that may go into `destination`; the rest (a
    /// collection dropped into its own descendant) are left where they were.
    @discardableResult
    func move(_ items: [ReaderLibraryItemRef], to destination: String?) -> Bool {
        var moved = false
        for item in items where item != .collection(destination ?? "") {
            moved = collections.move(item, to: destination) || moved
        }
        if moved { commitCollections() }
        return moved
    }

    /// A book dropped on another book: both go into a new collection at the
    /// target's level, Home Screen style. Returns the new collection's ID.
    func makeCollection(
        combining target: ReaderLibraryItemRef,
        with dropped: [ReaderLibraryItemRef]
    ) -> String? {
        let others = dropped.filter { $0 != target }
        guard !others.isEmpty else { return nil }
        let parent = collections.parent(of: target)
        let id = collections.createCollection(
            named: collections.unusedName(L10n.text("New Collection"), in: parent),
            in: parent
        )
        for item in [target] + others {
            collections.move(item, to: id)
        }
        commitCollections()
        return id
    }

    @discardableResult
    func createCollection(in parentID: String?, named name: String? = nil) -> String {
        let id = collections.createCollection(
            named: name ?? collections.unusedName(L10n.text("New Collection"), in: parentID),
            in: parentID
        )
        commitCollections()
        return id
    }

    func renameCollection(_ id: String, to name: String) {
        collections.rename(id, to: name)
        commitCollections()
    }

    func deleteCollection(_ id: String) {
        collections.delete(id)
        commitCollections()
    }

    /// Persists the tree, refreshes the grid, and mirrors the change to
    /// iCloud. The local write lands first, so an edit never waits on the
    /// network and is never lost to it.
    private func commitCollections() {
        collectionStore.save(collections)
        refreshGridForLastQuery()
        syncCollections(pullFirst: false)
    }

    private func refreshGridForLastQuery() {
        if let query = lastQuery {
            rebuildViewData(searchText: query.searchText, sortMode: query.sortMode)
        }
    }

    /// Merges this device's tree with the other devices' copy in iCloud.
    ///
    /// `pullFirst` (on reload) reads the cloud tree and pushes only when this
    /// device has something it lacks; after a local edit the push itself
    /// reads, merges and writes. Either way the result is merged back into
    /// whatever the tree holds *now*, so an edit made while the round trip
    /// was in flight is kept rather than overwritten. Offline, nothing
    /// happens and the next reload or edit tries again.
    private func syncCollections(pullFirst: Bool) {
        collectionSyncTask?.cancel()
        let sync = collectionSync
        let snapshot = collections
        collectionSyncTask = Task { [weak self] in
            var merged = snapshot
            if pullFirst {
                let cloud = await sync.load()
                if let cloud { merged = ReaderCollectionTree.merged(snapshot, cloud) }
                if merged != cloud, let pushed = try? await sync.push(merged) { merged = pushed }
            } else if let pushed = try? await sync.push(snapshot) {
                merged = pushed
            }
            guard !Task.isCancelled, let self else { return }
            let current = ReaderCollectionTree.merged(self.collections, merged)
            guard current != self.collections else { return }
            self.collections = current
            self.collectionStore.save(current)
            self.refreshGridForLastQuery()
        }
    }

    // MARK: - Library sync

    /// The Library's sync button: everything the library keeps in iCloud,
    /// and nothing else — book files and their metadata (both formats),
    /// collections, and reading positions. The Anki collection has its own
    /// sync and is not touched here.
    func syncLibrary() async {
        guard !isSyncingLibrary else { return }
        isSyncingLibrary = true
        defer { isSyncingLibrary = false }

        async let epubSync = epubLibraryClient.syncWithICloud()
        async let pdfSync = pdfLibraryClient.syncWithICloud()
        let (epub, pdf) = await (epubSync, pdfSync)
        let unavailable = epub.status == .unavailable && pdf.status == .unavailable
        let failed = epub.status == .failed || pdf.status == .failed
        let failureMessage = epub.message ?? pdf.message

        // A reload merges collections and reading positions from iCloud
        // (and flushes any position that never reached it), and picks up
        // books the sync restored.
        if let query = lastQuery {
            await reload(searchText: query.searchText, sortMode: query.sortMode)
        }
        await collectionSyncTask?.value

        if unavailable {
            actionError = L10n.text("iCloud Drive isn't available. Sign in to iCloud on this device to sync your library.")
        } else if failed {
            actionError = failureMessage
                ?? L10n.text("Some books couldn't be synced. Try again in a moment.")
        }
    }

    // MARK: - Book actions

    /// Whether a book is a file this library manages (EPUB or PDF), and so
    /// can be shared, renamed and removed. Books drawn from an Anki deck
    /// belong to the deck.
    func isManagedFile(_ bookID: String) -> Bool {
        switch bookIndex[bookID]?.source {
        case .epub, .pdf: true
        default: false
        }
    }

    func isFinished(_ bookID: String) -> Bool {
        (progressByBook[bookID]?.progress ?? 0) >= 1
    }

    func hasStarted(_ bookID: String) -> Bool {
        (progressByBook[bookID]?.progress ?? 0) > 0
    }

    /// Marks a book finished (at its last chapter) or unread (back to the
    /// start). Written through the reading-progress store, so it syncs to
    /// other devices like any position, and the book leaves (or rejoins)
    /// Continue accordingly.
    func setFinished(_ bookID: String, _ finished: Bool) {
        guard let book = bookIndex[bookID] else { return }
        let chapterID = (finished ? book.chapters.last?.id : book.chapters.first?.id) ?? 0
        progress.save(bookID: bookID, chapterID: chapterID, progress: finished ? 1 : 0)
        progressByBook[bookID] = progress.store.load(bookID: bookID)
        refreshGridForLastQuery()
    }

    /// Takes a book out of Continue without touching its position. It comes
    /// back by itself the next time it is read, as in Apple Books.
    func removeFromContinue(_ bookID: String) {
        continueHidden[bookID] = .now
        Self.saveContinueHidden(continueHidden)
        refreshGridForLastQuery()
    }

    private static var continueHiddenKey: String {
        let profile = UserDefaults.standard.string(forKey: "amgi.selectedUser") ?? "default"
        return "amgi.reader.continueHidden__\(profile)"
    }

    private static func loadContinueHidden() -> [String: Date] {
        guard let stored = UserDefaults.standard.dictionary(forKey: continueHiddenKey) as? [String: Double] else {
            return [:]
        }
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func saveContinueHidden(_ hidden: [String: Date]) {
        UserDefaults.standard.set(hidden.mapValues(\.timeIntervalSince1970), forKey: continueHiddenKey)
    }

    func renameBook(_ bookID: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let book = bookIndex[bookID], book.title != trimmed else { return }
        do {
            switch book.source {
            case .epub: try await epubLibraryClient.renameBook(bookID, trimmed)
            case .pdf: try await pdfLibraryClient.renameBook(bookID, trimmed)
            case .ankiDeck: return
            }
        } catch {
            actionError = error.localizedDescription
            return
        }
        replaceBook(bookID) { $0.title = trimmed }
    }

    /// Removes a book from this device's library. Its iCloud Drive copy is
    /// kept (deletes are local by design), and its reading position stays,
    /// so re-adding it picks up where it was.
    func removeBook(_ bookID: String) async {
        guard let book = bookIndex[bookID] else { return }
        do {
            switch book.source {
            case .epub: try await epubLibraryClient.deleteBook(bookID)
            case .pdf: try await pdfLibraryClient.deleteBook(bookID)
            case .ankiDeck: return
            }
        } catch {
            actionError = error.localizedDescription
            return
        }
        books.removeAll { $0.id == bookID }
        bookIndex[bookID] = nil
        refreshGridForLastQuery()
    }

    /// Updates one book in place and redraws, without a full reload.
    private func replaceBook(_ bookID: String, _ change: (inout ReaderBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        change(&books[index])
        bookIndex[bookID] = books[index]
        refreshGridForLastQuery()
    }

    // MARK: - Repair from any level

    /// `retryRepair` plus the reload that shows the result, for screens that
    /// do not own the library's search state (collection screens).
    func retryRepairAndReload(bookID: String) async -> Bool {
        let repaired = await retryRepair(bookID: bookID)
        if repaired, let query = lastQuery {
            startReload(searchText: query.searchText, sortMode: query.sortMode)
        }
        return repaired
    }

    func relinkAndReload(bookID: String, to url: URL) async throws {
        try await relink(bookID: bookID, to: url)
        if let query = lastQuery {
            startReload(searchText: query.searchText, sortMode: query.sortMode)
        }
    }

    /// Optimistically inserts or updates an imported book in the visible library.
    func upsertImportedBook(_ book: ReaderBook, searchText: String, sortMode: BookshelfSortMode) async {
        books.removeAll { $0.id == book.id }
        books.insert(book, at: 0)
        bookIndex[book.id] = book

        if localCoverURLs[book.id] == nil {
            let coverURL: URL?
            switch book.source {
            case .epub:
                coverURL = await epubLibraryClient.coverURL(book.id)
            case .pdf:
                coverURL = await pdfLibraryClient.coverURL(book.id)
            case .ankiDeck:
                coverURL = nil
            }
            if let coverURL {
                localCoverURLs[book.id] = coverURL
            }
        }

        rebuildViewData(searchText: searchText, sortMode: sortMode)
    }
}
