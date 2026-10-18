import AmgiReader
import AmgiAppCore
import AmgiAppShared
import Sharing
package import SwiftUI
import AmgiUI
import AssistantFeature
import UniformTypeIdentifiers

// MARK: - Sort mode

enum BookshelfSortMode: String, CaseIterable, Identifiable {
    case recent
    case title
    case progress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent:   L10n.text("Recently Read")
        case .title:    L10n.text("Title")
        case .progress: L10n.text("Progress")
        }
    }
}

// MARK: - Library view

/// Library container: owns navigation, search, sheets, and the toolbar, and
/// drives a `ReaderLibraryModel` for load/import. Rendering is delegated to
/// `ReaderLibraryContent`; the model owns all I/O so the View is thin
/// presentation wiring with no direct engine access.
package struct ReaderLibraryView: View {
    /// Bumped by the host after sync / import / review so the shelf reloads.
    /// Keyed into `.task` rather than applied as an `.id` — an `.id` change
    /// discards the whole subtree, throwing away the search text and scroll
    /// position to achieve a reload the task already does.
    private let refreshID: UUID?

    @State private var model: ReaderLibraryModel
    /// Off while a book is pushed on top or another tab shows, so the shelf
    /// never stands in for what is actually on screen.
    @State private var isOnScreen = false

    @Shared(.appStorage(ReaderPreferenceKey.deckName)) private var deckName: String = ""
    @Shared(.appStorage(ReaderPreferences.Keys.bookshelfSortMode))
    private var sortModeRaw: String = BookshelfSortMode.recent.rawValue

    @State private var searchText: String = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isImporting: Bool = false
    @State private var showConfiguration: Bool = false

    /// Files handed over by Finder, Files, AirDrop or drag-and-drop, waiting
    /// for the library to be ready to import them.
    ///
    /// The router is drained here because this is the first place with a live
    /// model. Nothing consumed it before, so a dropped file was accepted by the
    /// app, routed, and then quietly discarded — the file appeared to do
    /// nothing at all, which reads as a broken drop target rather than a
    /// missing feature.
    @State private var droppedRequestID: UUID?
    @State private var passageTarget: PassageTarget?

    struct PassageTarget: Identifiable, Hashable {
        let book: ReaderBook
        let anchor: ReaderSourceAnchor
        var id: String { book.id + "#" + String(describing: anchor.chapterID) }
    }

    package init(refreshID: UUID? = nil) {
        self.refreshID = refreshID
        _model = State(initialValue: ReaderLibraryModel())
    }

    /// Preview / test seam — lets a caller inside the module inject a
    /// pre-populated model. Deliberately not public.
    init(model: ReaderLibraryModel) {
        self.refreshID = nil
        _model = State(initialValue: model)
    }

    private var sortMode: BookshelfSortMode {
        BookshelfSortMode(rawValue: sortModeRaw) ?? .recent
    }

    /// The shelf as the grid orders it, for the assistant.
    private var shelfLines: [String] {
        model.sortedCells.map { cell in
            var line = cell.title
            if let author = cell.author, !author.isEmpty { line += " — \(author)" }
            if let progress = cell.progress { line += " (\(Int((progress * 100).rounded()))% read)" }
            return line
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(macOS)
        return .toolbar
        #else
        return horizontalSizeClass == .compact
            ? .navigationBarDrawer(displayMode: .always)
            : .toolbar
        #endif
    }

    /// A search that matched nothing; without it the shelf goes blank under
    /// its "All Books" heading.
    private var showsNoResults: Bool {
        guard case .loaded(let data) = model.state,
              !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return data.grid.isEmpty && data.continueReading.isEmpty
    }

    package var body: some View {
        ReaderLibraryContent(
            state: model.state,
            bookForId: { model.book(for: $0) },
            progress: model.progress,
            onImport: { isImporting = true },
            onConfigure: { showConfiguration = true },
            onRetry: { model.startReload(searchText: searchText, sortMode: sortMode) },
            repairActions: ReaderLibraryContent.BookRepairActions(
                retry: { bookID in
                    let repaired = await model.retryRepair(bookID: bookID)
                    if repaired {
                        model.startReload(searchText: searchText, sortMode: sortMode)
                    }
                    return repaired
                },
                relink: { bookID, url in
                    try await model.relink(bookID: bookID, to: url)
                    model.startReload(searchText: searchText, sortMode: sortMode)
                }
            )
        )
        // The grid, collection screens and Move sheet all edit collections
        // through the one model, so they stay in step.
        .environment(model)
        .preference(key: AssistantScreenContextKey.self, value: isOnScreen ? [.shelf(books: shelfLines)] : [])
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.isImportingBooks {
                    ProgressView()
                        .controlSize(.small)
                }
                // Syncs the library (books, collections, positions) through
                // iCloud — not the Anki collection, which has its own sync.
                Button {
                    Task { await model.syncLibrary() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: model.isSyncingLibrary)
                }
                .disabled(model.isSyncingLibrary)
                .help("Sync Library")
                .accessibilityLabel(model.isSyncingLibrary ? "Syncing library" : "Sync library")
                // "…", not "+": the floating + is Quick Capture, and this
                // menu is mostly about the library itself, as in Apple Books.
                Menu { libraryMenu } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Library options")
            }
        }
        .overlay {
            if showsNoResults {
                ContentUnavailableView.search(text: searchText)
            }
        }
        // Books-scoped native search (spec §5.1 v2): no Browse involvement.
        // Placed like Browse's: a pill pinned under the title on iPhone,
        // the toolbar field on iPad and Mac.
        .searchable(
            text: $searchText,
            placement: searchPlacement,
            prompt: "Search books and authors…"
        )
        .onChange(of: searchText) { _, _ in model.rebuildViewData(searchText: searchText, sortMode: sortMode) }
        .onChange(of: sortModeRaw) { _, _ in model.rebuildViewData(searchText: searchText, sortMode: sortMode) }
        .onChange(of: deckName) { _, _ in model.startReload(searchText: searchText, sortMode: sortMode) }
        .refreshable { await model.reload(searchText: searchText, sortMode: sortMode) }
        .task(id: refreshID) { model.startReload(searchText: searchText, sortMode: sortMode) }
        .onChange(of: ReaderImportRequestRouter.shared.requestID) { _, _ in
            Task { await importDroppedFiles() }
        }
        // Browse's "Open in Book": a card's passage, opened over the library.
        .onChange(of: ReaderOpenRequestRouter.shared.pending?.id) { _, _ in
            Task { await openRequestedPassage() }
        }
        .onChange(of: model.books.count) { _, _ in
            Task { await openRequestedPassage() }
        }
        .navigationDestination(item: $passageTarget) { target in
            ReaderOpenView(book: target.book, progress: model.progress, anchor: target.anchor)
        }
        .task {
            // A file can arrive before this view exists — the app was launched
            // by the drop — so the queue is drained once on appear as well as
            // on every subsequent change.
            await importDroppedFiles()
        }
        .sheet(isPresented: $showConfiguration) {
            NavigationStack {
                ReaderConfigurationView {
                    showConfiguration = false
                    model.startReload(searchText: searchText, sortMode: sortMode)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: UTType.readerDocuments,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result: result)
        }
        // Book actions from any level (collection screens included) fail
        // here: one alert for the stack rather than one per grid.
        .alert("Library", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Import failed", isPresented: Binding(
            get: { model.importError != nil },
            set: { if !$0 { model.importError = nil } }
        )) {
            Button("OK") { model.importError = nil }
        } message: {
            Text(model.importError ?? "")
        }
    }

    @ViewBuilder
    private var libraryMenu: some View {
        Button { isImporting = true } label: {
            Label("Import EPUB or PDF…", systemImage: "square.and.arrow.down")
        }
        Button { model.createCollection(in: nil) } label: {
            Label("New Collection", systemImage: "folder.badge.plus")
        }
        Divider()
        Menu("Sort by") {
            ForEach(BookshelfSortMode.allCases) { mode in
                Button {
                    $sortModeRaw.withLock { $0 = mode.rawValue }
                } label: {
                    if sortMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        }
        Divider()
        Button { showConfiguration = true } label: {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
    }

    /// Imports anything the system handed us that has not been imported yet.
    ///
    /// Requests are consumed one at a time and re-checked against the active
    /// profile, because a file dropped for one profile must not land in
    /// another's library.
    private func importDroppedFiles() async {
        let router = ReaderImportRequestRouter.shared
        let profileID = AccountStore.shared.selectedID
        while let request = router.consume(profileID: profileID) {
            await model.importBooks(
                [request.url],
                searchText: searchText,
                sortMode: sortMode
            )
        }
        droppedRequestID = router.requestID
    }

    /// Opens a requested card passage once its book is in the library list
    /// (a cold launch may still be loading it; `books` changing retries).
    private func openRequestedPassage() async {
        let router = ReaderOpenRequestRouter.shared
        let profileID = AccountStore.shared.selectedID
        guard let request = router.pending, request.profileID == profileID,
              let book = model.books.first(where: { $0.id == request.bookID }) else { return }
        _ = router.consume(profileID: profileID)
        let store = ReaderAnnotationStore(
            libraryRoot: AccountStore.profileDirectory(for: profileID)
                .appendingPathComponent("EPUB", isDirectory: true)
        )
        guard let mark = try? await store.annotations(inBook: book.id, kind: .card)
            .first(where: { $0.id == request.annotationID }) else { return }
        passageTarget = PassageTarget(book: book, anchor: mark.anchor)
    }

    private func handleImport(result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task { await model.importBooks(urls, searchText: searchText, sortMode: sortMode) }
        case .failure(let error):
            model.importError = error.localizedDescription
        }
    }
}
