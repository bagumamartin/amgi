import AmgiReader
import AmgiAppCore
import AmgiAppShared
import Sharing
package import SwiftUI
import AmgiUI
import UniformTypeIdentifiers

// MARK: - Sort mode

enum BookshelfSortMode: String, CaseIterable, Identifiable {
    case recent
    case title
    case progress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent:   "Recently Read"
        case .title:    "Title"
        case .progress: "Progress"
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

    @Shared(.appStorage(ReaderPreferenceKey.deckName)) private var deckName: String = ""
    @Shared(.appStorage(ReaderPreferences.Keys.bookshelfSortMode))
    private var sortModeRaw: String = BookshelfSortMode.recent.rawValue

    @State private var searchText: String = ""
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
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SyncToolbarButton()
                Menu { plusMenu } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Library actions")
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search books"
        )
        // Books-scoped native search (spec §5.1 v2): no Browse involvement.
        .searchMinimizedIfAvailable()
        .onChange(of: searchText) { _, _ in model.rebuildViewData(searchText: searchText, sortMode: sortMode) }
        .onChange(of: sortModeRaw) { _, _ in model.rebuildViewData(searchText: searchText, sortMode: sortMode) }
        .onChange(of: deckName) { _, _ in model.startReload(searchText: searchText, sortMode: sortMode) }
        .refreshable { await model.reload(searchText: searchText, sortMode: sortMode) }
        .task(id: refreshID) { model.startReload(searchText: searchText, sortMode: sortMode) }
        .onChange(of: ReaderImportRequestRouter.shared.requestID) { _, _ in
            Task { await importDroppedFiles() }
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
    private var plusMenu: some View {
        Button { isImporting = true } label: {
            Label("Import EPUB or PDF…", systemImage: "square.and.arrow.down")
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

    private func handleImport(result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task { await model.importBooks(urls, searchText: searchText, sortMode: sortMode) }
        case .failure(let error):
            model.importError = error.localizedDescription
        }
    }
}
