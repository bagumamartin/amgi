// iOS-only component — Menu/popover/listRowSeparator APIs are unavailable on watchOS.
#if !os(watchOS)
public import SwiftUI
import AmgiTheme

/// Pure rendering surface for the Library screen. Owns no I/O. Takes a
/// single state value + callbacks for mutations. The container in the
/// app target maps domain rows (`DeckListRow` etc.) to `DeckRowViewData`
/// and reconstructs domain types from callback payloads.
public struct LibraryListContent: View {
    public enum State: Equatable, Hashable, Sendable {
        case loading
        case empty
        case loaded(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData)
    }

    let state: State
    @Binding var sortOrder: DeckSortOrder
    let onRefresh: () async -> Void
    let onStartReview: () -> Void
    let onTapDeck: (DeckRowViewData) -> Void
    let onDeleteDeck: (Int64) async -> Void
    let onRenameDeck: (DeckRowViewData) -> Void

    // Nested `State` enum shadows SwiftUI's `@State`; qualify the wrapper.
    @SwiftUI.State private var deleteTarget: DeckRowViewData?
    @Environment(\.palette) private var palette

    public init(
        state: State,
        sortOrder: Binding<DeckSortOrder>,
        onRefresh: @escaping () async -> Void,
        onStartReview: @escaping () -> Void,
        onTapDeck: @escaping (DeckRowViewData) -> Void,
        onDeleteDeck: @escaping (Int64) async -> Void,
        onRenameDeck: @escaping (DeckRowViewData) -> Void
    ) {
        self.state = state
        self._sortOrder = sortOrder
        self.onRefresh = onRefresh
        self.onStartReview = onStartReview
        self.onTapDeck = onTapDeck
        self.onDeleteDeck = onDeleteDeck
        self.onRenameDeck = onRenameDeck
    }

    public var body: some View {
        switch state {
        case .loading:
            ProgressView()
        case .empty:
            ContentUnavailableView(
                "No Decks",
                systemImage: "rectangle.stack",
                description: Text("Sync with your server to get your decks.")
            )
        case .loaded(let rows, let hero, let heatmap):
            loadedList(rows: rows, hero: hero, heatmap: heatmap)
                .alert(
                    "Delete \"\(deleteTarget?.name ?? "")\"?",
                    isPresented: Binding(
                        get: { deleteTarget != nil },
                        set: { if !$0 { deleteTarget = nil } }
                    )
                ) {
                    Button("Delete", role: .destructive) {
                        guard let target = deleteTarget else { return }
                        deleteTarget = nil
                        Task { await onDeleteDeck(target.id) }
                    }
                    Button("Cancel", role: .cancel) { deleteTarget = nil }
                } message: {
                    Text("This will permanently delete the deck and all its cards.")
                }
        }
    }

    @ViewBuilder
    private func loadedList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData) -> some View {
        List {
            Section {
                LibraryHeroCard(data: hero, onStartReview: onStartReview)
                    // Matching top/bottom insets so the List doesn't clip
                    // the card's corners and shadow. Horizontal width is
                    // the centered column (`LibraryColumn.maxWidth`).
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(rows) { row in
                    DeckListRowView(
                        data: row,
                        onTap: { onTapDeck(row) },
                        onRequestDelete: { deleteTarget = row },
                        onRename: { onRenameDeck(row) }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(palette.surfaceElevated)
                    .listRowSeparatorTint(palette.separator)
                }
            } header: {
                DeckSectionHeader(title: "Decks", sortOrder: $sortOrder)
            }

            Section {
                ActivityHeatmapCard(data: heatmap)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .libraryListStyle()
        .environment(\.defaultMinListRowHeight, 0)
        .scrollClipDisabled()
        .scrollContentBackground(.hidden)
        // Cap the List itself — not scroll margins derived from the List's
        // width. Measuring after `contentMargins` collapsed to ~800 and
        // dropped the cap whenever the iPad sidebar stole space.
        .frame(maxWidth: LibraryColumn.maxWidth)
        .frame(maxWidth: .infinity)
        .refreshable { await onRefresh() }
    }
}

/// Shared Library column width. Hero, decks, and activity all live in
/// this List, so they stay aligned. Independent of sidebar / split width.
private enum LibraryColumn {
    static let maxWidth: CGFloat = 800
}

private extension View {
    /// `insetGrouped` is iOS-only. On macOS (preview-only target),
    /// fall back to the platform default.
    @ViewBuilder
    func libraryListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self
        #endif
    }
}

// MARK: - Previews

#if DEBUG
private extension DeckRowViewData {
    static let sampleKorean = DeckRowViewData(
        id: 1, name: "한국어", fullName: "한국어",
        newCount: 20, learnCount: 93, reviewCount: 74,
        isFiltered: false, subdeckCount: 4
    )
    static let sampleEnglish = DeckRowViewData(
        id: 2, name: "English", fullName: "English",
        newCount: 0, learnCount: 67, reviewCount: 200,
        isFiltered: false, subdeckCount: 0
    )
    static let sampleCS = DeckRowViewData(
        id: 3, name: "ComputerScience", fullName: "ComputerScience",
        newCount: 20, learnCount: 35, reviewCount: 72,
        isFiltered: false, subdeckCount: 0
    )
    static let sampleEspanol = DeckRowViewData(
        id: 4, name: "Español", fullName: "Español",
        newCount: 0, learnCount: 0, reviewCount: 0,
        isFiltered: false, subdeckCount: 0
    )
    static let sampleFiltered = DeckRowViewData(
        id: 5, name: "Hardest cards", fullName: "Hardest cards",
        newCount: 0, learnCount: 0, reviewCount: 24,
        isFiltered: true, subdeckCount: 0
    )
}

private extension HeroData {
    static let samplePopulated = HeroData(
        totalDue: 680, deckCount: 7, streak: 36,
        recentDayTotals: HeroData.sampleDayTotals()
    )
}

#Preview("Loaded — populated") {
    NavigationStack {
        LibraryListContent(
            state: .loaded(
                rows: [.sampleKorean, .sampleEnglish, .sampleCS, .sampleEspanol, .sampleFiltered],
                hero: .samplePopulated,
                heatmap: .dense
            ),
            sortOrder: .constant(.mostUsed),
            onRefresh: {}, onStartReview: {},
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}

#Preview("Loaded — zero due") {
    NavigationStack {
        LibraryListContent(
            state: .loaded(
                rows: [.sampleEspanol],
                hero: HeroData(totalDue: 0, deckCount: 1, streak: 12,
                               recentDayTotals: Array(repeating: 0, count: HeroData.sparklineCapacity)),
                heatmap: .sparse
            ),
            sortOrder: .constant(.mostUsed),
            onRefresh: {}, onStartReview: {},
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}

#Preview("Loading") {
    NavigationStack {
        LibraryListContent(
            state: .loading,
            sortOrder: .constant(.mostUsed),
            onRefresh: {}, onStartReview: {},
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}

#Preview("Empty") {
    NavigationStack {
        LibraryListContent(
            state: .empty,
            sortOrder: .constant(.mostUsed),
            onRefresh: {}, onStartReview: {},
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}
#endif
#endif  // !os(watchOS)
