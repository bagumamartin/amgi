// AmgiApp/Sources/Decks/DeckList/DeckListView.swift
import SwiftUI
import AmgiTheme
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies
import Sharing

/// Library container: owns navigation, sheets, and the toolbar, and drives
/// a `DeckListModel` for load/refresh + deck mutations. Rendering is
/// delegated to `LibraryListContent` (AmgiUI); data assembly lives in the
/// model. The View is intentionally thin — presentation wiring only.
struct DeckListView: View {
    /// Library's hero represents the complete active collection rather than
    /// a particular deck. The host presents the virtual all-decks review
    /// scope when this is invoked.
    let onStartReview: () -> Void
    @Dependency(\.collectionStore) private var store
    @Shared(.appStorage(NavigationPreferences.deckSortOrder)) private var sortOrderRaw: String = DeckSortOrder.mostUsed.rawValue
    @State private var model: DeckListModel
    @State private var showCreateSheet = false
    @State private var renameTarget: DeckRowViewData?
    @State private var iconTarget: DeckRowViewData?
    @State private var pendingDeck: DeckInfo?

    private var sortOrderBinding: Binding<DeckSortOrder> {
        Binding(
            get: { DeckSortOrder(rawValue: sortOrderRaw) ?? .mostUsed },
            set: { newOrder in
                $sortOrderRaw.withLock { $0 = newOrder.rawValue }
                model.resort(sortOrder: newOrder)
            }
        )
    }

    init(
        model: DeckListModel = DeckListModel(),
        onStartReview: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: model)
        self.onStartReview = onStartReview
    }

    var body: some View {
        LibraryListContent(
            state: model.state,
            sortOrder: sortOrderBinding,
            onRefresh: { await model.load(sortOrder: sortOrderBinding.wrappedValue) },
            onStartReview: onStartReview,
            onTapDeck: { row in pendingDeck = row.asDeckInfo },
            onDeleteDeck: { rawID in await model.delete(DeckID(rawID)) },
            onRenameDeck: { row in renameTarget = row },
            onChangeIconDeck: { row in iconTarget = row }
        )
        .navigationTitle("Library")
        .navigationDestination(item: $pendingDeck) { deck in
            DeckDetailView(deck: deck)
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
        // Keyed on the store's generation: any Invalidation (deck mutation,
        // sync, import, review-end) re-runs the load; `.task` still cancels
        // on disappear.
        .task(id: store.generation) {
            await model.load(sortOrder: sortOrderBinding.wrappedValue)
        }
        .onAppear {
            model.resort(sortOrder: sortOrderBinding.wrappedValue)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Browse drill-in — seedless entry; profile menu moved to the
            // shared .accountMenu() installed by MainTabView.
            Button {
                BrowseLauncher.shared.launch()
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .help("Browse cards and notes")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("New Deck", systemImage: "plus") {
                showCreateSheet = true
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    // Preview clients keep refresh/delete working in the live canvas;
    // the seeded `.loaded` state makes the first snapshot deterministic
    // instead of racing the async `.task` load.
    let model = withDependencies {
        $0.deckClient = .previewValue
        $0.statsClient = .previewValue
    } operation: {
        DeckListModel()
    }
    model.state = .loaded(
        rows: [
            DeckRowViewData(
                id: 1, name: "한국어", fullName: "한국어",
                newCount: 20, learnCount: 93, reviewCount: 74,
                isFiltered: false, subdeckCount: 4
            ),
            DeckRowViewData(
                id: 2, name: "English", fullName: "English",
                newCount: 0, learnCount: 67, reviewCount: 200,
                isFiltered: false, subdeckCount: 0
            ),
            DeckRowViewData(
                id: 3, name: "Hardest cards", fullName: "Hardest cards",
                newCount: 0, learnCount: 0, reviewCount: 24,
                isFiltered: true, subdeckCount: 0
            ),
        ],
        hero: HeroData(
            totalDue: 478, deckCount: 3, streak: 36,
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        heatmap: .empty
    )
    return NavigationStack {
        DeckListView(model: model)
    }
    .environment(\.palette, .vividLight)
}

#Preview("Minimal") {
    // Same seeded state as the default preview — mirrors it but pins the
    // minimal theme's light palette to eyeball ring elevation + monogram
    // tiles + cobalt accent.
    let model = withDependencies {
        $0.deckClient = .previewValue
        $0.statsClient = .previewValue
    } operation: {
        DeckListModel()
    }
    model.state = .loaded(
        rows: [
            DeckRowViewData(
                id: 1, name: "한국어", fullName: "한국어",
                newCount: 20, learnCount: 93, reviewCount: 74,
                isFiltered: false, subdeckCount: 4
            ),
            DeckRowViewData(
                id: 2, name: "English", fullName: "English",
                newCount: 0, learnCount: 67, reviewCount: 200,
                isFiltered: false, subdeckCount: 0
            ),
            DeckRowViewData(
                id: 3, name: "Hardest cards", fullName: "Hardest cards",
                newCount: 0, learnCount: 0, reviewCount: 24,
                isFiltered: true, subdeckCount: 0
            ),
        ],
        hero: HeroData(
            totalDue: 478, deckCount: 3, streak: 36,
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        heatmap: .empty
    )
    return NavigationStack {
        DeckListView(model: model)
    }
    .environment(\.palette, ThemeRegistry.shared.palette(id: .minimal, scheme: .light))
}
#endif
