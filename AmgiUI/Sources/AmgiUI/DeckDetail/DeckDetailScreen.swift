public import SwiftUI
import AmgiTheme

/// Pure presentation layer for the deck-detail screen. Holds no I/O —
/// drives entirely off `DeckDetailViewState`. The Container in AmgiApp
/// performs the data fetches and pipes a `DeckDetailViewData` in.
///
/// Composition top→bottom (matches `design/deck.jsx`):
///   • Hero — flag tile + large title + subtitle (+ Custom Study chip)
///   • DeckDetailTile — NEW / LEARNING / REVIEW counts
///   • DeckStudyButton — full-width Study Now pill
///   • DeckCustomStudyCard — filtered decks only (Rebuild / Empty)
///   • DeckSubdecksCard — active children; parked children live under Archived
///     and that header is omitted entirely when none are parked
///   • heatmapSlot — Container-injected (R03)
///   • InsightsCard
public struct DeckDetailScreen<HeatmapSlot: View>: View {
    public enum Action: Equatable, Sendable {
        case studyNow
        case customStudy
        case addNote
        case stats
        case browse
        case rebuild
        case emptyDeck
        case subdeckSelected(DeckSubdeckRowData)
        case renameSubdeck(DeckSubdeckRowData)
        case changeSubdeckIcon(DeckSubdeckRowData)
        case deleteSubdeck(DeckSubdeckRowData)
    }

    public let state: DeckDetailViewState
    @Binding public var sortOrder: DeckSortOrder
    public let heatmapSlot: () -> HeatmapSlot
    public let onAction: (Action) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var archivedExpanded = false

    public init(
        state: DeckDetailViewState,
        sortOrder: Binding<DeckSortOrder>,
        @ViewBuilder heatmapSlot: @escaping () -> HeatmapSlot,
        onAction: @escaping (Action) -> Void
    ) {
        self.state = state
        self._sortOrder = sortOrder
        self.heatmapSlot = heatmapSlot
        self.onAction = onAction
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = DeckDetailLayout.resolve(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView {
                if layout == .wide {
                    wideLayout
                } else {
                    narrowLayout
                }
            }
            .frame(maxWidth: layout.maximumContentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .amgiScreenCanvas()
    }

    @ViewBuilder
    private var narrowLayout: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            heroSection
            statsSection
            ctaSection
            #if os(iOS)
            quickActionsSection
            #endif
            customStudySection
            subdecksSection
            heatmapSection
            insightsSection
        }
    }

    @ViewBuilder
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 24) {
            LazyVStack(alignment: .leading, spacing: 18) {
                heroSection
                statsSection
                ctaSection
                customStudySection
                subdecksSection
            }
            .frame(minWidth: DeckDetailLayout.minimumPrimaryWidth, maxWidth: .infinity, alignment: .top)

            LazyVStack(alignment: .leading, spacing: 18) {
                #if os(iOS)
                quickActionsSection
                #endif
                heatmapSection
                insightsSection
            }
            .frame(
                minWidth: DeckDetailLayout.minimumSecondaryWidth,
                idealWidth: 360,
                maxWidth: 440,
                alignment: .top
            )
        }
    }

    @ViewBuilder
    private var quickActionsSection: some View {
        if case .loaded(let data) = state {
            HStack(spacing: 8) {
                quickAction("Add", systemImage: "plus", action: .addNote)
                quickAction("Stats", systemImage: "chart.bar", action: .stats)
                if !data.isFiltered {
                    quickAction("Browse", systemImage: "magnifyingglass", action: .browse)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        switch state {
        case .loading:
            DeckHero(title: "Deck name", subtitle: "Last studied recently", tone: palette.border, deckName: "📚", isFiltered: false)
                .redacted(reason: .placeholder)
        case .loaded(let data):
            DeckHero(
                title: data.title,
                subtitle: data.subtitle,
                tone: data.tone,
                deckName: data.deckName,
                iconName: data.iconName,
                isFiltered: data.isFiltered
            )
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        switch state {
        case .loading:
            DeckDetailTile(data: .zero)
                .redacted(reason: .placeholder)
        case .loaded(let data):
            DeckDetailTile(data: data.tileCounts)
        }
    }

    @ViewBuilder
    private var ctaSection: some View {
        switch state {
        case .loading:
            DeckStudyButton(isDisabled: true, onTap: {})
        case .loaded(let data):
            HStack(spacing: 12) {
                DeckStudyButton(isDisabled: data.isEmpty) { onAction(.studyNow) }
                if !data.isFiltered { customStudyButton }
            }
        }
    }

    private var customStudyButton: some View {
        Button { onAction(.customStudy) } label: {
            Text("Custom Study")
                .amgiFont(size: 15, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Create a focused session from this deck and its subdecks")
    }

    private func quickAction(_ title: String, systemImage: String, action: Action) -> some View {
        Button { onAction(action) } label: {
            Label(title, systemImage: systemImage)
                .amgiFont(size: 14, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var customStudySection: some View {
        if case .loaded(let data) = state, data.isFiltered {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Custom study")
                DeckCustomStudyCard(
                    isActionInFlight: data.isActionInFlight,
                    onRebuild: { onAction(.rebuild) },
                    onEmpty: { onAction(.emptyDeck) }
                )
            }
        }
    }

    @ViewBuilder
    private var subdecksSection: some View {
        if case .loaded(let data) = state {
            let active = data.subdecks.filter { !$0.isArchived }
            let archived = data.subdecks.filter(\.isArchived)
            if !active.isEmpty || !archived.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    if !active.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            DeckSectionHeader(title: "Subdecks", sortOrder: $sortOrder)
                            subdecksCard(rows: active)
                        }
                    }
                    if !archived.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ArchivedSectionHeader(
                                count: archived.count,
                                itemNoun: "subdecks",
                                isExpanded: $archivedExpanded
                            )
                            if archivedExpanded {
                                subdecksCard(rows: archived)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subdecksCard(rows: [DeckSubdeckRowData]) -> some View {
        DeckSubdecksCard(rows: rows) { row in
            onAction(.subdeckSelected(row))
        } onRename: { row in
            onAction(.renameSubdeck(row))
        } onChangeIcon: { row in
            onAction(.changeSubdeckIcon(row))
        } onDelete: { row in
            onAction(.deleteSubdeck(row))
        }
    }

    @ViewBuilder
    private var heatmapSection: some View {
        if case .loaded = state {
            heatmapSlot()
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        if case .loaded(let data) = state {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Insights")
                InsightsCard(data: data.insights)
            }
        }
    }

    // MARK: - Row primitives

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .amgiFont(size: 12, weight: .semibold, tracking: 0.4)
            .textCase(.uppercase)
            .foregroundStyle(palette.textTertiary)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}

/// Resolves the detail composition from the width actually assigned to the
/// deck detail. A regular size class alone is not enough: an iPad split pane
/// can be regular while still being narrower than a desktop detail column.
enum DeckDetailLayout: Equatable {
    case narrow
    case wide

    static let minimumPrimaryWidth: CGFloat = 520
    static let minimumSecondaryWidth: CGFloat = 320
    static let columnSpacing: CGFloat = 24
    static let minimumWideWidth: CGFloat = minimumPrimaryWidth
        + minimumSecondaryWidth
        + columnSpacing
        + 64

    static func resolve(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool = false
    ) -> DeckDetailLayout {
        guard !isAccessibilitySize, availableWidth >= minimumWideWidth else {
            return .narrow
        }
        return .wide
    }

    var maximumContentWidth: CGFloat {
        switch self {
        case .narrow: 800
        case .wide: 1_200
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .narrow: 20
        case .wide: 32
        }
    }
}

// MARK: - Previews

#if DEBUG
private let _krChildren: [DeckSubdeckRowData] = [
    DeckSubdeckRowData(id: 1, name: "Vocab Typing", fullName: "한국어::Vocab Typing", newCount: 20, learnCount: 0, reviewCount: 5, isFiltered: false),
    DeckSubdeckRowData(id: 2, name: "Cloze Grammar", fullName: "한국어::Cloze Grammar", newCount: 0, learnCount: 4, reviewCount: 9, isFiltered: false),
    DeckSubdeckRowData(id: 3, name: "Collocations", fullName: "한국어::Collocations", newCount: 0, learnCount: 14, reviewCount: 0, isFiltered: false),
    DeckSubdeckRowData(id: 4, name: "Manual Tags", fullName: "한국어::Manual Tags", newCount: 20, learnCount: 3, reviewCount: 3, isFiltered: false),
    DeckSubdeckRowData(id: 5, name: "Old Series", fullName: "한국어::Old Series", newCount: 0, learnCount: 0, reviewCount: 0, isFiltered: false, isArchived: true),
]

private let _krDefault = DeckDetailViewData(
    title: "한국어",
    subtitle: "Last studied today · 32-day streak",
    tone: .red,
    deckName: "🇰🇷 한국어",
    tileCounts: DeckDetailTileData(newCount: 20, learnCount: 93, reviewCount: 74),
    isFiltered: false,
    isEmpty: false,
    subdecks: _krChildren,
    insights: InsightsCardData(retention30dPercent: 86, avgCardsPerDay: 59, matureCards: 200),
    isActionInFlight: false
)

private let _krFiltered = DeckDetailViewData(
    title: "한국어 (Filtered)",
    subtitle: "Last studied today · 32-day streak",
    tone: .red,
    deckName: "🇰🇷 한국어",
    tileCounts: DeckDetailTileData(newCount: 20, learnCount: 93, reviewCount: 74),
    isFiltered: true,
    isEmpty: false,
    subdecks: [],
    insights: InsightsCardData(retention30dPercent: 86, avgCardsPerDay: 59, matureCards: 200),
    isActionInFlight: false
)

private let _krEmpty = DeckDetailViewData(
    title: "한국어",
    subtitle: "No cards yet · Add some to start studying",
    tone: .red,
    deckName: "🇰🇷 한국어",
    tileCounts: .zero,
    isFiltered: false,
    isEmpty: true,
    subdecks: [],
    insights: .empty,
    isActionInFlight: false
)

#Preview("Default") {
    NavigationStack {
        DeckDetailScreen(
            state: .loaded(_krDefault),
            sortOrder: .constant(.mostUsed),
            heatmapSlot: { EmptyView() },
            onAction: { _ in }
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("Filtered") {
    NavigationStack {
        DeckDetailScreen(
            state: .loaded(_krFiltered),
            sortOrder: .constant(.mostUsed),
            heatmapSlot: { EmptyView() },
            onAction: { _ in }
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("Empty") {
    NavigationStack {
        DeckDetailScreen(
            state: .loaded(_krEmpty),
            sortOrder: .constant(.mostUsed),
            heatmapSlot: { EmptyView() },
            onAction: { _ in }
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("Loading") {
    NavigationStack {
        DeckDetailScreen(
            state: .loading,
            sortOrder: .constant(.mostUsed),
            heatmapSlot: { EmptyView() },
            onAction: { _ in }
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("Default — dark") {
    NavigationStack {
        DeckDetailScreen(
            state: .loaded(_krDefault),
            sortOrder: .constant(.mostUsed),
            heatmapSlot: { EmptyView() },
            onAction: { _ in }
        )
    }
    .environment(\.palette, .vividDark)
    .preferredColorScheme(.dark)
}

#Preview("With heatmap slot") {
    NavigationStack {
        DeckDetailScreen(
            state: .loaded(_krDefault),
            sortOrder: .constant(.mostUsed),
            heatmapSlot: {
                Rectangle()
                    .fill(Palette.vividLight.accentSoft)
                    .frame(height: 80)
                    .overlay { Text("heatmap (R03)").font(.caption).foregroundStyle(.secondary) }
            },
            onAction: { _ in }
        )
    }
    .environment(\.palette, .vividLight)
}
#endif
