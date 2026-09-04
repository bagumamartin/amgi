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
        /// A load that threw. Distinct from `.empty`: rendering a failure as
        /// the new-user empty state told a user with a full collection that
        /// they had no decks, and offered them a Create Deck button for it.
        case failed(String)
        /// `heatmap` is nil while the review-history fetch is still in flight.
        /// The rows and the hero's due counts come from the deck tree and do
        /// not wait on it — a year of revlog used to gate the whole screen.
        case loaded(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData?)
    }

    let state: State
    @Binding var sortOrder: DeckSortOrder
    let onRefresh: () async -> Void
    let onStartReview: () -> Void
    let onTapDeck: (DeckRowViewData) -> Void
    let onDeleteDeck: (Int64) async -> Void
    let onRenameDeck: (DeckRowViewData) -> Void
    let onCreateDeck: () -> Void
    let onChangeIconDeck: (DeckRowViewData) -> Void
    /// Namespace the container's deck-detail push zooms from. Optional
    /// because the row rendering is useful in previews and tests that have
    /// no navigation stack to anchor to.
    let deckTransition: Namespace.ID?

    // Nested `State` enum shadows SwiftUI's `@State`; qualify the wrapper.
    @SwiftUI.State private var deleteTarget: DeckRowViewData?
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        state: State,
        sortOrder: Binding<DeckSortOrder> = .constant(.mostUsed),
        onRefresh: @escaping () async -> Void,
        onStartReview: @escaping () -> Void,
        onTapDeck: @escaping (DeckRowViewData) -> Void,
        onDeleteDeck: @escaping (Int64) async -> Void,
        onRenameDeck: @escaping (DeckRowViewData) -> Void,
        onCreateDeck: @escaping () -> Void,
        onChangeIconDeck: @escaping (DeckRowViewData) -> Void = { _ in },
        deckTransition: Namespace.ID? = nil
    ) {
        self.state = state
        self._sortOrder = sortOrder
        self.onRefresh = onRefresh
        self.onStartReview = onStartReview
        self.onTapDeck = onTapDeck
        self.onDeleteDeck = onDeleteDeck
        self.onRenameDeck = onRenameDeck
        self.onCreateDeck = onCreateDeck
        self.onChangeIconDeck = onChangeIconDeck
        self.deckTransition = deckTransition
    }

    public var body: some View {
        switch state {
        case .loading:
            ProgressView()
        case .empty:
            ContentUnavailableView {
                Label("No Decks", systemImage: "rectangle.stack")
            } description: {
                Text("Sync with your server, or create a deck to get started.")
            } actions: {
                Button("Create Deck", action: onCreateDeck)
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Decks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await onRefresh() } }
                    .buttonStyle(.borderedProminent)
            }
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
    private func loadedList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData?) -> some View {
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
    private func deckList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData?) -> some View {
        List {
            Section {
                LibraryHeroCard(
                    data: hero,
                    activityPending: heatmap == nil,
                    onStartReview: onStartReview
                )
                    // Full-bleed horizontally, like the heatmap card. Bottom
                    // inset clears the card's shadow (radius 16–20, dy 4–6),
                    // which the row would otherwise clip.
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 12, trailing: 0))
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
                    // One modifier, not four. Chained inline, the ForEach
                    // element type is a four-deep ModifiedContent nest, and
                    // AttributeGraph describes that whole type per row.
                    .modifier(DeckRowChrome(
                        rowID: row.id,
                        namespace: deckTransition,
                        isFirst: index == 0,
                        isLast: index == rows.count - 1,
                        surface: palette.surfaceElevated,
                        border: palette.border
                    ))
                }
            } header: {
                DeckSectionHeader(title: "Decks", sortOrder: $sortOrder)
            }

            Section {
                ActivityHeatmapCard(data: heatmap ?? .empty, initialDays: heatmapInitialDays)
                    .redacted(reason: heatmap == nil ? .placeholder : [])
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
    #endif

    #if os(macOS)
    private func scrollList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LibraryHeroCard(
                    data: hero,
                    activityPending: heatmap == nil,
                    onStartReview: onStartReview
                )

                VStack(alignment: .leading, spacing: 6) {
                    DeckSectionHeader(title: "Decks", sortOrder: $sortOrder)
                    deckRowsCard(rows: rows)
                }

                ActivityHeatmapCard(data: heatmap ?? .empty, initialDays: heatmapInitialDays)
                    .redacted(reason: heatmap == nil ? .placeholder : [])
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
                    onRename: { onRenameDeck(row) },
                    onChangeIcon: { onChangeIconDeck(row) }
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

/// Every per-row list modifier in one place, including anchoring the row as
/// the zoom source for the detail push when the container supplied a
/// namespace to anchor into. The grouped-card stroke is folded in so the
/// ForEach element type stays a single ModifiedContent nest.
private struct DeckRowChrome: ViewModifier {
    let rowID: Int64
    let namespace: Namespace.ID?
    let isFirst: Bool
    let isLast: Bool
    let surface: Color
    let border: Color

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(deckCardBackground)
            .listRowSeparator(.hidden)
            .modifier(DeckTransitionSource(id: rowID, namespace: namespace))
    }

    @ViewBuilder
    private var deckCardBackground: some View {
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
            .fill(surface)

            DeckCardStrokeShape(isFirst: isFirst, isLast: isLast, cornerRadius: r)
                .stroke(border, lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(border)
                    .frame(height: 0.5)
                    .padding(.leading, 68)
            }
        }
    }
}

private struct DeckTransitionSource: ViewModifier {
    let id: Int64
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            #if os(iOS)
            content.matchedTransitionSource(id: id, in: namespace)
            #else
            content
            #endif
        } else {
            content
        }
    }
}

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

/// AttributeGraph cannot compare a view that stores closures: a function
/// value carries no `Equatable` conformance, so `LayoutDescriptor::Builder`
/// walks the type's fields and asks the runtime a conformance question per
/// field — the path that dominated the CPU profile
/// (`swift_conformsToProtocol*`, 352 ms of self time in a 76 s capture).
/// Declaring equality over the data this view actually renders lets
/// `.equatable()` short-circuit with a value compare instead.
///
/// Sound because every stored closure writes to the container's `@State`
/// through a wrapper that is stable across body passes, and none of them
/// reads a value that changes between passes. `@Environment` changes still
/// invalidate normally — `EquatableView` does not suppress those.
extension LibraryListContent: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
            && lhs.deckTransition == rhs.deckTransition
            && lhs.sortOrder == rhs.sortOrder
    }
}

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
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }, onCreateDeck: {}
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}

#Preview("Loaded — Minimal palette") {
    // Same seeded state as the populated preview, pinned to the minimal
    // theme's light palette to eyeball ring elevation + monogram tiles +
    // cobalt accent. Lived on DeckListView until that view moved into
    // DecksFeature, where previews can no longer link the Rust engine.
    NavigationStack {
        LibraryListContent(
            state: .loaded(
                rows: [.sampleKorean, .sampleEnglish, .sampleCS, .sampleEspanol, .sampleFiltered],
                hero: .samplePopulated,
                heatmap: .dense
            ),
            sortOrder: .constant(.mostUsed),
            onRefresh: {}, onStartReview: {},
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }, onCreateDeck: {}
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, ThemeRegistry.shared.palette(id: .minimal, scheme: .light))
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
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }, onCreateDeck: {}
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
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }, onCreateDeck: {}
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
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }, onCreateDeck: {}
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}
#endif
#endif  // !os(watchOS)
