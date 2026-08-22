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
    let onChangeIconDeck: (DeckRowViewData) -> Void

    // Nested `State` enum shadows SwiftUI's `@State`; qualify the wrapper.
    @SwiftUI.State private var deleteTarget: DeckRowViewData?
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        state: State,
        sortOrder: Binding<DeckSortOrder>,
        onRefresh: @escaping () async -> Void,
        onStartReview: @escaping () -> Void,
        onTapDeck: @escaping (DeckRowViewData) -> Void,
        onDeleteDeck: @escaping (Int64) async -> Void,
        onRenameDeck: @escaping (DeckRowViewData) -> Void,
        onChangeIconDeck: ((DeckRowViewData) -> Void)? = nil
    ) {
        self.state = state
        self._sortOrder = sortOrder
        self.onRefresh = onRefresh
        self.onStartReview = onStartReview
        self.onTapDeck = onTapDeck
        self.onDeleteDeck = onDeleteDeck
        self.onRenameDeck = onRenameDeck
        self.onChangeIconDeck = onChangeIconDeck ?? { _ in }
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
        #if os(iOS)
        GeometryReader { proxy in
            let inset = LibraryColumn.inset(for: proxy.size.width)
            if inset > 0 {
                deckList(rows: rows, hero: hero, heatmap: heatmap)
                    // Inset the List *content* (not the List frame) so the
                    // scroll indicator stays at the screen edge while the rows
                    // stay centered on regular-width layouts. Compact widths skip
                    // this so the insetGrouped style keeps its native margins.
                    .contentMargins(.horizontal, inset, for: .scrollContent)
            } else {
                deckList(rows: rows, hero: hero, heatmap: heatmap)
            }
        }
        #else
        // `List` doesn't honor `contentMargins` on macOS, and swipe actions are
        // touch-only — use a full-bleed ScrollView with a centered column so the
        // scroll indicator stays at the window edge.
        scrollList(rows: rows, hero: hero, heatmap: heatmap)
        #endif
    }

    private var heatmapInitialDays: Int {
        horizontalSizeClass == .regular ? 365 : 180
    }

    #if os(iOS)
    private func deckList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData) -> some View {
        List {
            Section {
                LibraryHeroCard(data: hero, onStartReview: onStartReview)
                    // Matching top/bottom insets so the List doesn't clip
                    // the card's corners and shadow.
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    DeckListRowView(
                        data: row,
                        onTap: { onTapDeck(row) },
                        onRequestDelete: { deleteTarget = row },
                        onRename: { onRenameDeck(row) },
                        onChangeIcon: { onChangeIconDeck(row) }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(
                        deckCardBackground(
                            isFirst: index == 0,
                            isLast: index == rows.count - 1
                        )
                    )
                    .listRowSeparator(.hidden)
                }
            } header: {
                DeckSectionHeader(title: "Decks", sortOrder: $sortOrder)
            }

            Section {
                ActivityHeatmapCard(data: heatmap, initialDays: heatmapInitialDays)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollClipDisabled()
        .scrollContentBackground(.hidden)
        .refreshable { await onRefresh() }
    }

    @ViewBuilder
    private func deckCardBackground(isFirst: Bool, isLast: Bool) -> some View {
        let r = AmgiRadius.inset
        ZStack {
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: isFirst ? r : 0,
                    bottomLeading: isLast ? r : 0,
                    bottomTrailing: isLast ? r : 0,
                    topTrailing: isFirst ? r : 0
                ),
                style: .continuous
            )
            .fill(palette.surfaceElevated)

            DeckCardStrokeShape(isFirst: isFirst, isLast: isLast, cornerRadius: r)
                .stroke(palette.border, lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(palette.border)
                    .frame(height: 0.5)
                    .padding(.leading, 68)
            }
        }
    }
    #endif

    #if os(macOS)
    private func scrollList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LibraryHeroCard(data: hero, onStartReview: onStartReview)

                VStack(alignment: .leading, spacing: 6) {
                    DeckSectionHeader(title: "Decks", sortOrder: $sortOrder)
                    deckRowsCard(rows: rows)
                }

                ActivityHeatmapCard(data: heatmap, initialDays: heatmapInitialDays)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 32)
            .frame(maxWidth: LibraryColumn.maxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background.ignoresSafeArea())
        .refreshable { await onRefresh() }
    }

    private func deckRowsCard(rows: [DeckRowViewData]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                DeckListRowView(
                    data: row,
                    onTap: { onTapDeck(row) },
                    onRequestDelete: { deleteTarget = row },
                    onRename: { onRenameDeck(row) }
                )
                .padding(.horizontal, 12)
                .overlay(alignment: .bottom) {
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(palette.border)
                            .frame(height: 0.5)
                            .padding(.leading, 64)
                    }
                }
            }
        }
        .background(
            palette.surfaceElevated,
            in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
    }
    #endif
}

#if os(iOS)
/// Outer-boundary stroke for the Library deck card, split per row so the
/// rounded top/bottom corners land on the first/last row and the left/right
/// edges stay continuous across the middle rows.
private struct DeckCardStrokeShape: Shape {
    let isFirst: Bool
    let isLast: Bool
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: 0.25, dy: 0.25)
        let r = cornerRadius
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        var path = Path()

        if isFirst {
            path.move(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addArc(
                center: CGPoint(x: minX + r, y: minY + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: maxX - r, y: minY))
            path.addArc(
                center: CGPoint(x: maxX - r, y: minY + r),
                radius: r,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        } else if isLast {
            path.move(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY - r))
            path.addArc(
                center: CGPoint(x: maxX - r, y: maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
            path.addArc(
                center: CGPoint(x: minX + r, y: maxY - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: minX, y: minY))
        } else {
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.move(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        }

        return path
    }
}
#endif

/// Shared Library content column width. Hero, decks, and activity all
/// align to this centered column so they stay readable on regular-width
/// layouts without pinning the scroll indicator to the column edge.
private enum LibraryColumn {
    static let maxWidth: CGFloat = 800

    /// Horizontal margin that centers the column when the detail pane is
    /// wider than `maxWidth`. Compact widths return 0, leaving the
    /// insetGrouped style's native margins untouched.
    static func inset(for width: CGFloat) -> CGFloat {
        max(0, (width - maxWidth) / 2)
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
