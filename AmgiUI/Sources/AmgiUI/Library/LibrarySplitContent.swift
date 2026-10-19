#if !os(watchOS)
public import SwiftUI
import AmgiTheme

/// What the Library's detail pane shows on iPad landscape and Mac, where
/// the deck list is a column beside it.
public enum LibraryColumnSelection: Hashable, Sendable {
    case today
    case deck(Int64)
}

/// The first row of the Library list column. Selecting it shows the
/// collection's Today summary — the hero and activity that sit above the
/// decks on iPhone — in the detail pane.
public struct LibraryTodayRow: View {
    let hero: HeroData
    let activityPending: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    public init(hero: HeroData, activityPending: Bool, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.hero = hero
        self.activityPending = activityPending
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                        .fill(palette.warning.opacity(0.16))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "sun.max.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(palette.warning)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AmgiL10n.text("Today", locale: locale))
                            .amgiFont(.body)
                            .bold()
                            .foregroundStyle(palette.textPrimary)
                        // One line when it fits; otherwise due over studied,
                        // never a break after the middle dot.
                        ViewThatFits(in: .horizontal) {
                            Text("\(dueText) · \(studiedText)")
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(dueText)
                                Text(studiedText)
                            }
                        }
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .redacted(reason: activityPending ? .placeholder : [])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            HeroStreakIndicator(
                summary: HeroStreakSummary(streak: hero.streak, dayTotals: hero.recentDayTotals)
            )
            .frame(width: 118)
            .fixedSize(horizontal: false, vertical: true)
            .redacted(reason: activityPending ? .placeholder : [])
            .disabled(activityPending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(isSelected ? palette.accent.opacity(0.12) : palette.surfaceElevated, in: shape)
        .overlay(shape.strokeBorder(isSelected ? palette.accent.opacity(0.35) : palette.border, lineWidth: 0.5))
    }

    private var dueText: String {
        AmgiL10n.format("%lld due", [hero.totalDue], locale: locale)
    }

    private var studiedText: String {
        AmgiL10n.format("%lld studied", [hero.today?.studied ?? 0], locale: locale)
    }
}

/// The Library's Today pane: the hero and the activity heatmap, which on
/// iPhone sit above and below the deck list.
public struct LibraryTodayPane: View {
    let state: LibraryListContent.State
    /// A "Today" heading, matching the list pane's "Library", where the bar
    /// has no title of its own (iPad).
    let showsHeading: Bool
    let onRefresh: () async -> Void

    @Environment(\.palette) private var palette

    public init(state: LibraryListContent.State, showsHeading: Bool = false, onRefresh: @escaping () async -> Void) {
        self.state = state
        self.showsHeading = showsHeading
        self.onRefresh = onRefresh
    }

    public var body: some View {
        Group {
            switch state {
            case .loaded(_, let hero, let heatmap, _):
                ScrollView {
                    VStack(alignment: .leading, spacing: AmgiPage.sectionSpacing) {
                        if showsHeading {
                            Text("Today")
                                .font(.largeTitle)
                                .bold()
                                .foregroundStyle(palette.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                                .amgiPageHeading()
                        }
                        LibraryHeroCard(data: hero, activityPending: heatmap == nil, layout: .pane)
                        ActivityHeatmapCard(data: heatmap ?? .empty, initialDays: 365)
                            .redacted(reason: heatmap == nil ? .placeholder : [])
                    }
                    .amgiPageContent(.fill)
                }
                .amgiReportsHeadingScroll()
                .refreshable { await onRefresh() }
            case .loading:
                ProgressView()
            case .empty, .failed:
                // The list column carries the empty and error states and
                // their actions; repeating them here would offer two of each.
                Color.clear
            }
        }
        .amgiScreenCanvas()
    }
}

#if DEBUG
#Preview("Today row") {
    VStack(spacing: 12) {
        LibraryTodayRow(
            hero: HeroData(totalDue: 413, deckCount: 4, streak: 0,
                           recentDayTotals: HeroData.sampleDayTotals(), today: .sample),
            activityPending: false, isSelected: true, onSelect: {}
        )
        LibraryTodayRow(
            hero: HeroData(totalDue: 413, deckCount: 4, streak: 12,
                           recentDayTotals: HeroData.sampleDayTotals(), today: .sample),
            activityPending: false, isSelected: false, onSelect: {}
        )
    }
    .padding(16)
    .frame(width: 360)
    .environment(\.palette, .vividLight)
}
#endif
#endif  // !os(watchOS)
