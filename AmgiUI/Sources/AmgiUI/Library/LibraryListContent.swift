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
    let onRefresh: () async -> Void
    let onStartReview: () -> Void
    let onTapDeck: (DeckRowViewData) -> Void
    let onDeleteDeck: (Int64) async -> Void
    let onRenameDeck: (DeckRowViewData) -> Void
    let onCreateDeck: () -> Void
    /// Namespace the container's deck-detail push zooms from. Optional
    /// because the row rendering is useful in previews and tests that have
    /// no navigation stack to anchor to.
    let deckTransition: Namespace.ID?

    @Environment(\.palette) private var palette

    public init(
        state: State,
        onRefresh: @escaping () async -> Void,
        onStartReview: @escaping () -> Void,
        onTapDeck: @escaping (DeckRowViewData) -> Void,
        onDeleteDeck: @escaping (Int64) async -> Void,
        onRenameDeck: @escaping (DeckRowViewData) -> Void,
        onCreateDeck: @escaping () -> Void,
        deckTransition: Namespace.ID? = nil
    ) {
        self.deckTransition = deckTransition
        self.state = state
        self.onRefresh = onRefresh
        self.onStartReview = onStartReview
        self.onTapDeck = onTapDeck
        self.onDeleteDeck = onDeleteDeck
        self.onRenameDeck = onRenameDeck
        self.onCreateDeck = onCreateDeck
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
        }
    }

    @ViewBuilder
    private func loadedList(rows: [DeckRowViewData], hero: HeroData, heatmap: HeatmapCardData?) -> some View {
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

            Section("Decks") {
                ForEach(rows) { row in
                    DeckListRowView(
                        data: row,
                        onTap: { onTapDeck(row) },
                        onDelete: { Task { await onDeleteDeck(row.id) } },
                        onRename: { onRenameDeck(row) }
                    )
                    // One modifier, not four. Chained inline, the ForEach
                    // element type is a four-deep ModifiedContent nest, and
                    // AttributeGraph describes that whole type per row.
                    .modifier(DeckRowChrome(
                        rowID: row.id,
                        namespace: deckTransition,
                        background: palette.surfaceElevated,
                        separator: palette.separator
                    ))
                }
            }

            Section {
                ActivityHeatmapCard(data: heatmap ?? .empty)
                    .redacted(reason: heatmap == nil ? .placeholder : [])
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .libraryListStyle()
        .scrollContentBackground(.hidden)
        .refreshable { await onRefresh() }
    }
}

/// Every per-row list modifier in one place, including anchoring the row as
/// the zoom source for the detail push when the container supplied a
/// namespace to anchor into.
private struct DeckRowChrome: ViewModifier {
    let rowID: Int64
    let namespace: Namespace.ID?
    let background: Color
    let separator: Color

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(background)
            .listRowSeparatorTint(separator)
            .modifier(DeckTransitionSource(id: rowID, namespace: namespace))
    }
}

private struct DeckTransitionSource: ViewModifier {
    let id: Int64
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
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
        lhs.state == rhs.state && lhs.deckTransition == rhs.deckTransition
    }
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
        last14Days: [3, 5, 2, 7, 6, 9, 4, 8, 6, 5, 7, 3, 8, 5]
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
                               last14Days: Array(repeating: 0, count: 14)),
                heatmap: .sparse
            ),
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
            onRefresh: {}, onStartReview: {},
            onTapDeck: { _ in }, onDeleteDeck: { _ in }, onRenameDeck: { _ in }, onCreateDeck: {}
        )
        .navigationTitle("Library")
    }
    .environment(\.palette, .vividLight)
}
#endif
#endif  // !os(watchOS)
