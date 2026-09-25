import AmgiReader
import AmgiAppCore
import AmgiAppShared
import Sharing
package import SwiftUI
import AmgiTheme
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
    /// The root regular-width shell owns navigation. In that context the
    /// reader shelf is stack-only instead of nesting another split view.
    private let embeddedInRootWorkspace: Bool

    @State private var model: ReaderLibraryModel

    @Shared(.appStorage(ReaderPreferenceKey.deckName)) private var deckName: String = ""
    @Shared(.appStorage(ReaderPreferences.Keys.bookshelfSortMode))
    private var sortModeRaw: String = BookshelfSortMode.recent.rawValue

    @State private var searchText: String = ""
    @State private var isImporting: Bool = false
    @State private var showConfiguration: Bool = false
    @State private var selectedBookID: String?
    @State private var isDropTargeted = false
    @State private var importRouter = ReaderImportRequestRouter.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.palette) private var palette

    package init(
        refreshID: UUID? = nil,
        embeddedInRootWorkspace: Bool = false
    ) {
        self.refreshID = refreshID
        self.embeddedInRootWorkspace = embeddedInRootWorkspace
        _model = State(initialValue: ReaderLibraryModel())
    }

    /// Preview / test seam — lets a caller inside the module inject a
    /// pre-populated model. Deliberately not public.
    init(model: ReaderLibraryModel) {
        self.refreshID = nil
        self.embeddedInRootWorkspace = false
        _model = State(initialValue: model)
    }

    private var sortMode: BookshelfSortMode {
        BookshelfSortMode(rawValue: sortModeRaw) ?? .recent
    }

    package var body: some View {
        libraryLayout
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncToolbarButton()
                    Menu { plusMenu } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Library actions")
                }
            }
            .onChange(of: searchText) { _, _ in model.rebuildViewData(searchText: searchText, sortMode: sortMode) }
            .onChange(of: sortModeRaw) { _, _ in model.rebuildViewData(searchText: searchText, sortMode: sortMode) }
            .onChange(of: deckName) { _, _ in model.startReload(searchText: searchText, sortMode: sortMode) }
            .onChange(of: importRouter.requestID) { _, _ in importExternalEPUBs() }
            .refreshable { await model.reload(searchText: searchText, sortMode: sortMode) }
            .task(id: refreshID) {
                model.startReload(searchText: searchText, sortMode: sortMode)
                importExternalEPUBs()
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
                allowedContentTypes: [epubType],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result: result)
            }
            .dropDestination(for: URL.self) { urls, _ in
                importDroppedURLs(urls)
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(palette.accentSoft)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        }
                        .overlay {
                            Label("Drop EPUB files to add them", systemImage: "square.and.arrow.down")
                                .amgiFont(.cardTitle)
                                .foregroundStyle(palette.accent)
                                .padding(20)
                                .amgiMaterial(.regular, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(20)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(AmgiMotion.quick, value: isDropTargeted)
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
    private var libraryLayout: some View {
        if embeddedInRootWorkspace {
            embeddedLibraryLayout
        } else if horizontalSizeClass == .compact {
            libraryContent(onSelectBook: nil)
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search books"
                )
                .searchMinimizedIfAvailable()
        } else {
            NavigationSplitView {
                libraryContent(onSelectBook: selectBook)
                    .searchable(
                        text: $searchText,
                        placement: .toolbar,
                        prompt: "Search books"
                    )
                    .searchMinimizedIfAvailable()
                    .navigationTitle("Library")
                    .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 560)
            } detail: {
                if let selectedBook {
                    ReaderBookDetailView(book: selectedBook, progress: model.progress)
                        .id(selectedBook.id)
                } else {
                    ContentUnavailableView(
                        "Select a Book",
                        systemImage: "books.vertical",
                        description: Text("Choose a title to see its details and chapters.")
                    )
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    /// The root shell owns navigation; the reader still gets a real
    /// list/detail workspace, but as two adjacent panes rather than another
    /// nested `NavigationSplitView`.
    private var embeddedLibraryLayout: some View {
        HStack(spacing: 0) {
            libraryContent(onSelectBook: selectBook)
                .frame(minWidth: 320, idealWidth: 420, maxWidth: 540)
                .searchable(
                    text: $searchText,
                    placement: .toolbar,
                    prompt: "Search books"
                )
                .searchMinimizedIfAvailable()
                .navigationTitle("Library")

            Divider()

            Group {
                if let selectedBook {
                    ReaderBookDetailView(book: selectedBook, progress: model.progress)
                        .id(selectedBook.id)
                } else {
                    ContentUnavailableView(
                        "Select a Book",
                        systemImage: "books.vertical",
                        description: Text("Choose a title to see its details and chapters.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func libraryContent(onSelectBook: ((String) -> Void)?) -> some View {
        ReaderLibraryContent(
            state: model.state,
            bookForId: { model.book(for: $0) },
            progress: model.progress,
            onSelectBook: onSelectBook,
            onImport: { isImporting = true },
            onConfigure: { showConfiguration = true },
            onRetry: { model.startReload(searchText: searchText, sortMode: sortMode) }
        )
    }

    private var selectedBook: ReaderBook? {
        selectedBookID.flatMap(model.book(for:))
    }

    private var epubType: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }

    private func selectBook(_ id: String) {
        selectedBookID = id
    }

    @ViewBuilder
    private var plusMenu: some View {
        Button { isImporting = true } label: {
            Label("Import EPUB…", systemImage: "square.and.arrow.down")
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

    private func importExternalEPUBs() {
        let profileID = AccountStore.shared.selectedID
        var urls: [URL] = []
        while let request = importRouter.consume(profileID: profileID) {
            urls.append(request.url)
        }
        guard !urls.isEmpty else { return }
        Task {
            await model.importEPUBs(urls, searchText: searchText, sortMode: sortMode)
        }
    }

    private func importDroppedURLs(_ urls: [URL]) -> Bool {
        let epubs = urls.filter {
            $0.isFileURL && $0.pathExtension.lowercased() == "epub"
        }
        guard !epubs.isEmpty else { return false }
        Task { await model.importEPUBs(epubs, searchText: searchText, sortMode: sortMode) }
        return true
    }

    private func handleImport(result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task { await model.importEPUBs(urls, searchText: searchText, sortMode: sortMode) }
        case .failure(let error):
            model.importError = error.localizedDescription
        }
    }
}
