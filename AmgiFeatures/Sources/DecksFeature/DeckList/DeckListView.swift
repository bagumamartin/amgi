package import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AppIntents
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies
import Sharing

/// Library container: owns navigation, sheets, and the toolbar, and drives
/// a `DeckListModel` for load/refresh + deck mutations. Rendering is
/// delegated to `LibraryListContent` (AmgiUI); data assembly lives in the
/// model. The View is intentionally thin — presentation wiring only.
package struct DeckListView: View {
    @Dependency(\.collectionStore) private var store
    @Shared(.appStorage(NavigationPreferences.deckSortOrder)) private var sortOrderRaw: String = DeckSortOrder.mostUsed.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: DeckListModel
    @State private var showCreateSheet = false
    @State private var showImport = false
    @State private var renameTarget: DeckRowViewData?
    @State private var iconTarget: DeckRowViewData?
    @State private var pendingDeck: DeckInfo?
    /// Selection for the regular-width list/detail layout. Unlike
    /// `pendingDeck`, this remains populated while its detail is visible so
    /// resizing the split view never falls back to an empty detail column.
    @State private var selectedDeck: DeckInfo?
    /// Deck detail grows out of the row that was tapped, rather than cutting
    /// in from the trailing edge — the row and the screen are the same thing.
    @Namespace private var deckTransition

    private let onOpenToday: () -> Void
    /// `true` when the root shell already owns the regular navigation split.
    /// The feature then presents a stack-only library instead of nesting a
    /// second `NavigationSplitView` inside the shell.
    private let embeddedInRootWorkspace: Bool

    /// Profile switching lives on the root sidebar footer (iPad / Mac) or the
    /// toolbar account menu (iPhone), not here — applying it twice doubled
    /// the leading profile pill.
    package init(
        onOpenToday: @escaping () -> Void = {},
        embeddedInRootWorkspace: Bool = false
    ) {
        self.onOpenToday = onOpenToday
        self.embeddedInRootWorkspace = embeddedInRootWorkspace
        _model = State(initialValue: DeckListModel())
    }

    /// Preview / test seam — internal so the model stays module-private.
    init(
        model: DeckListModel,
        onOpenToday: @escaping () -> Void = {},
        embeddedInRootWorkspace: Bool = false
    ) {
        self.onOpenToday = onOpenToday
        self.embeddedInRootWorkspace = embeddedInRootWorkspace
        _model = State(initialValue: model)
    }

    private var sortOrderBinding: Binding<DeckSortOrder> {
        Binding(
            get: { DeckSortOrder(rawValue: sortOrderRaw) ?? .mostUsed },
            set: { newOrder in
                $sortOrderRaw.withLock { $0 = newOrder.rawValue }
                model.resort(sortOrder: newOrder)
            }
        )
    }

    private var activityData: HeatmapCardData? {
        guard case .loaded(_, _, let heatmap) = model.state else { return nil }
        return heatmap
    }

    package var body: some View {
        let profile = AccountStore.shared.selectedContext
        return adaptiveLibraryLayout
            .appEntityIdentifierIfAvailable(forSelectionType: Int64.self) { rawID in
                guard let entity = DeckEntity(
                    context: profile,
                    deckID: DeckID(rawID),
                    name: "Deck"
                ) else { return nil }
                return EntityIdentifier(for: entity)
            }
            .navigationTitle("Library")
            .navigationDestination(item: $pendingDeck) { deck in
                deckDetail(for: deck, usesZoomTransition: true)
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showCreateSheet) {
                CreateDeckSheet {
                    showCreateSheet = false
                }
            }
            .sheet(item: $renameTarget) { row in
                RenameDeckSheet(deckId: DeckID(row.id), currentName: row.fullName) {
                    renameTarget = nil
                }
            }
            .sheet(item: $iconTarget) { row in
                DeckIconEditorSheet(deckId: row.id, deckName: row.name) {
                    iconTarget = nil
                }
            }
            .deckImport(isPresented: $showImport)
            // Keyed on the store's generation: any Invalidation (deck mutation,
            // sync, import, review-end) re-runs the load; `.task` still cancels
            // on disappear.
            .task(id: store.generation) { await model.load(sortOrder: sortOrderBinding.wrappedValue) }
            .onChange(of: horizontalSizeClass) { _, _ in
                migrateOpenDeckAcrossLayouts()
            }
    }

    @ViewBuilder
    private var adaptiveLibraryLayout: some View {
        if embeddedInRootWorkspace {
            embeddedLibraryLayout
        } else if usesSplitLibraryLayout {
            GeometryReader { proxy in
                // Let a genuinely large window give the Library enough room
                // for its wide hero/decks/activity composition, while an iPad
                // split pane keeps a compact list and nearly all width for
                // deck detail.
                let idealSidebarWidth = min(max(proxy.size.width * 0.45, 360), 620)
                libraryLayout(sidebarIdealWidth: idealSidebarWidth)
            }
        } else {
            // Keep the compact phone's original surface and proposal chain.
            libraryLayout(sidebarIdealWidth: 360)
        }
    }

    /// The root shell owns the outer navigation split. Library still gets a
    /// useful list/detail workspace, but uses a plain two-column HStack so it
    /// does not introduce a second `NavigationSplitView` owner.
    private var embeddedLibraryLayout: some View {
        HStack(spacing: 0) {
            libraryList
                .frame(minWidth: 320, idealWidth: 420, maxWidth: 520)
            Divider()
            Group {
                if let selectedDeck {
                    deckDetail(for: selectedDeck, usesZoomTransition: true)
                } else {
                    LibraryDetailPlaceholder(activityData: activityData)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func libraryLayout(sidebarIdealWidth: CGFloat) -> some View {
        if usesSplitLibraryLayout {
            NavigationSplitView {
                libraryList
                    .navigationSplitViewColumnWidth(min: 280, ideal: sidebarIdealWidth, max: 720)
            } detail: {
                if let selectedDeck {
                    deckDetail(for: selectedDeck, usesZoomTransition: true)
                } else {
                    LibraryDetailPlaceholder(activityData: activityData)
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            libraryList
        }
    }

    private var libraryList: some View {
        LibraryListContent(
            state: model.state,
            sortOrder: sortOrderBinding,
            onRefresh: { await model.load(sortOrder: sortOrderBinding.wrappedValue) },
            onOpenToday: onOpenToday,
            onTapDeck: { row in
                if isTwoPaneLayout {
                    selectedDeck = row.asDeckInfo
                    pendingDeck = nil
                } else {
                    pendingDeck = row.asDeckInfo
                    selectedDeck = nil
                }
            },
            onDeleteDeck: { rawID in await model.delete(DeckID(rawID)) },
            onRenameDeck: { row in renameTarget = row },
            onCreateDeck: { showCreateSheet = true },
            onChangeIconDeck: { row in iconTarget = row },
            showsActivity: !isTwoPaneLayout,
            deckTransition: deckTransition
        )
        // The pure content stores callbacks, which makes it incomparable to
        // AttributeGraph by default. Its custom equality compares rendered
        // data and keeps the hot list update on a value check.
        .equatable()
    }

    @ViewBuilder
    private func deckDetail(for deck: DeckInfo, usesZoomTransition: Bool) -> some View {
        let detail = DeckDetailView(deck: deck, activityData: activityData)
        if usesZoomTransition {
            #if os(iOS)
            detail
                .matchedTransitionSource(id: deck.id.rawValue, in: deckTransition)
                .navigationTransition(.zoom(sourceID: deck.id.rawValue, in: deckTransition))
            #else
            detail
            #endif
        } else {
            detail
        }
    }

    private var usesSplitLibraryLayout: Bool {
        guard !embeddedInRootWorkspace else { return false }
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    private var isTwoPaneLayout: Bool {
        usesSplitLibraryLayout || embeddedInRootWorkspace
    }

    /// A rotation or Split View resize should carry the open deck into the
    /// destination layout instead of making the user find it again.
    private func migrateOpenDeckAcrossLayouts() {
        if isTwoPaneLayout {
            if selectedDeck == nil { selectedDeck = pendingDeck }
            pendingDeck = nil
        } else {
            if pendingDeck == nil { pendingDeck = selectedDeck }
            selectedDeck = nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isTwoPaneLayout, selectedDeck != nil {
                // The detail column owns Sync/Import/Export while it is open.
                // Retain the one Library action that has no detail equivalent,
                // plus an explicit route back to the adaptive overview.
                Button {
                    selectedDeck = nil
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .accessibilityLabel("Show Library Overview")
                .help("Show Library Overview")
                Button("New Deck", systemImage: "plus") {
                    showCreateSheet = true
                }
            } else {
                // One glass capsule: Sync · Import · Export · New Deck. Browse
                // is its own tab — a Library push was leftover from the old
                // drill-in.
                SyncToolbarButton()
                Button {
                    showImport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import files")
                .help("Import Anki files")
                Button {
                    ExportRequestRouter.shared.request(
                        scope: .collection,
                        allowsScopeChange: true,
                        sourceName: "Library"
                    )
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export")
                .help("Export a deck, collection, or notes")
                Button("New Deck", systemImage: "plus") {
                    showCreateSheet = true
                }
            }
        }
    }
}

private struct LibraryDetailPlaceholder: View {
    let activityData: HeatmapCardData?

    var body: some View {
        if let activityData {
            ScrollView {
                ActivityHeatmapCard(data: activityData, initialDays: 365)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            }
        } else {
            ContentUnavailableView(
                "Select a Deck",
                systemImage: "rectangle.stack",
                description: Text("Choose a deck to keep the Library visible while you inspect and study it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Preview
//
// None here, deliberately. Previews of a package target run in XCPreviewAgent
// with no app host, and the JIT can only resolve symbols from dylibs in the
// products dir — `libanki_bridge_ios.a` is a static archive, so anything whose
// preview transitively reaches AnkiBackend fails to link with
// "Symbols not found: [_anki_open_backend, …]". DeckListView reaches it through
// DeckListModel, DeckDetailView, and ReviewView. It rendered while this file
// lived in the app target (AmgiApp.debug.dylib exports those four symbols);
// it cannot since the DecksFeature extraction.
//
// The deck list surface previews from `LibraryListContent` in AmgiUI instead —
// same pixels, engine-free, including the minimal-palette variant this file
// used to pin.
