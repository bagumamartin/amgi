public import SwiftUI
import AmgiTheme

/// Library hero card. Built on `AmgiHeroSummary`. The header is two
/// columns: due numeral, deck count and streak chip (`HeroStreakIndicator`)
/// on the left; today's
/// Studied/Time, Pace and Retention tiles stacked on the right. The footer
/// band is unused, which keeps the card short. The 14-day sparkline is the
/// sidecar (stacked on compact, beside copy on regular).
///
/// The due numeral and sparkline are collection facts. Starting today's
/// session belongs to Study, so this card does not play the queue.
public struct LibraryHeroCard: View {
    /// Where the card sits, which decides its arrangement.
    public enum Layout: Sendable {
        /// The Library list: the iPhone column, with the sparkline under it
        /// on compact and beside it on regular.
        case list
        /// The Library's Today pane on iPad landscape and Mac. Wide panes
        /// put the four tiles in one row with the graph under them, right
        /// of the due column. Narrow panes keep the iPhone arrangement at a
        /// larger size: due column and a 2×2 tile grid at equal height, the
        /// graph full width below.
        case pane
    }

    let data: HeroData
    let layout: Layout
    /// True while the review-history fetch that feeds `streak`,
    /// `last14Days` and `today` is still in flight. `totalDue` and
    /// `deckCount` come from the deck tree and are real immediately, so the
    /// card renders at once and only the history-derived decorations are
    /// shown as placeholders — a confident "0 day streak" that flips to 36
    /// a second later is a worse answer than an obvious placeholder.
    let activityPending: Bool

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    @State private var paneIsWide = true

    public init(
        data: HeroData,
        activityPending: Bool = false,
        layout: Layout = .list
    ) {
        self.data = data
        self.activityPending = activityPending
        self.layout = layout
    }

    public var body: some View {
        switch layout {
        case .list: listBody
        case .pane: paneBody
        }
    }

    private var listBody: some View {
        AmgiHeroSummary(
            header: {
                // A grid, not two stacks: the streak chip and Retention share
                // a row, so they line up top and bottom whatever the numeral
                // column's height. Column 0 is sized by the numeral block;
                // the chip takes that width without widening it.
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(AmgiL10n.text("Due today", locale: locale).uppercased(with: locale))
                                .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                                .foregroundStyle(palette.textTertiary)
                            // Digits have no descenders and the eyebrow
                            // already gives headroom: trim the line box to
                            // roughly the glyphs so the block matches the
                            // two tile rows beside it.
                            Text("\(data.totalDue)")
                                .amgiFont(size: 56, weight: .bold, tracking: -1.2, relativeTo: .largeTitle)
                                .foregroundStyle(palette.textPrimary)
                                .padding(.top, -4)
                                .padding(.bottom, -7)
                            Text(subtitleText)
                                .amgiFont(size: 15, weight: .regular, relativeTo: .subheadline)
                                .foregroundStyle(palette.textSecondary)
                        }
                        .fixedSize()
                        VStack(spacing: 8) {
                            HeroHeaderStatTiles(today: data.today ?? HeroTodayStats())
                                .redacted(reason: activityPending ? .placeholder : [])
                            paceTile
                        }
                    }
                    GridRow {
                        HeroStreakIndicator(
                            summary: HeroStreakSummary(streak: data.streak, dayTotals: data.recentDayTotals)
                        )
                        .redacted(reason: activityPending ? .placeholder : [])
                        .disabled(activityPending)
                        .gridCellUnsizedAxes(.horizontal)
                        HeroRetentionTile(today: data.today ?? HeroTodayStats())
                            .redacted(reason: activityPending ? .placeholder : [])
                    }
                }
                // Ideal heights, so the equal-height chip/Retention pair
                // stretches only to each other, never to a List proposal.
                .fixedSize(horizontal: false, vertical: true)
            },
            footer: {
                EmptyView()
            },
            sidecar: {
                sparkline
                    .redacted(reason: activityPending ? .placeholder : [])
            }
        )
    }

    // MARK: Pane layout

    private var paneBody: some View {
        AmgiCard(
            background: .surfaceElevated,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.hero
        ) {
            Group {
                if paneIsWide {
                    widePane
                } else {
                    narrowPane
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width >= LibraryHeroMetrics.minimumWidePaneWidth
            } action: { paneIsWide = $0 }
        }
    }

    /// Due column | four tiles over the graph.
    private var widePane: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                dueBlock
                Spacer(minLength: 0)
                streakChip
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    tile(.studied)
                    tile(.time)
                    tile(.pace)
                    tile(.retention)
                }
                .fixedSize(horizontal: false, vertical: true)
                sparkline
                    .frame(minHeight: LibraryHeroMetrics.paneSparklineMinHeight, maxHeight: .infinity)
                    .redacted(reason: activityPending ? .placeholder : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The iPhone hero, larger: due column and a 2×2 grid at one height,
    /// then the graph across the whole card.
    private var narrowPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    dueBlock
                    Spacer(minLength: 0)
                    streakChip
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        tile(.studied)
                        tile(.time)
                    }
                    GridRow {
                        tile(.pace)
                        tile(.retention)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            sparkline
                .frame(height: LibraryHeroMetrics.paneSparklineMinHeight)
                .redacted(reason: activityPending ? .placeholder : [])
        }
    }

    private var dueBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AmgiL10n.text("Due today", locale: locale).uppercased(with: locale))
                .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                .foregroundStyle(palette.textTertiary)
            Text("\(data.totalDue)")
                .amgiFont(size: 56, weight: .bold, tracking: -1.2, relativeTo: .largeTitle)
                .foregroundStyle(palette.textPrimary)
                .padding(.top, -4)
                .padding(.bottom, -7)
            Text(subtitleText)
                .amgiFont(size: 15, weight: .regular, relativeTo: .subheadline)
                .foregroundStyle(palette.textSecondary)
        }
        .fixedSize()
    }

    private var streakChip: some View {
        HeroStreakIndicator(
            summary: HeroStreakSummary(streak: data.streak, dayTotals: data.recentDayTotals)
        )
        .redacted(reason: activityPending ? .placeholder : [])
        .disabled(activityPending)
    }

    private enum PaneTile { case studied, time, pace, retention }

    @ViewBuilder
    private func tile(_ kind: PaneTile) -> some View {
        let today = data.today ?? HeroTodayStats()
        Group {
            switch kind {
            case .studied: HeroStudiedTile(today: today, fillsHeight: true)
            case .time: HeroTimeTile(today: today, fillsHeight: true)
            case .pace: paceTile(fillsHeight: true)
            case .retention: HeroRetentionTile(today: today)
            }
        }
        .redacted(reason: activityPending ? .placeholder : [])
    }

    private var paceTile: some View { paceTile(fillsHeight: false) }

    private func paceTile(fillsHeight: Bool) -> some View {
        let pace = AmgiL10n.format(
            "%.1f s/card",
            [(data.today ?? HeroTodayStats()).paceSecondsPerCard],
            locale: locale
        )
        return HeroStatTile(
            eyebrow: AmgiL10n.text("Pace", locale: locale),
            value: pace,
            accessibilityLabel: AmgiL10n.format("Pace, %@", [pace], locale: locale),
            valueFontSize: 14,
            verticalPadding: 6,
            horizontalPadding: 4,
            fillsHeight: fillsHeight
        )
        .redacted(reason: activityPending ? .placeholder : [])
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var sparkline: some View {
        SparklineBars(values: data.recentDayTotals)
            .frame(height: isRegular ? nil : LibraryHeroMetrics.compactSparklineHeight)
    }

    private var subtitleText: String {
        AmgiL10n.format(
            data.deckCount == 1 ? "across %lld deck" : "across %lld decks",
            [data.deckCount],
            locale: locale
        )
    }
}

// MARK: - 14-day sparkline

private struct SparklineBars: View {
    let values: [Int]

    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let visible = Self.visibleSlice(values: values, width: geo.size.width)
            let maxValue = max(visible.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.offset) { offset, value in
                    // A zero day is a faint baseline tick, not a short bar —
                    // the 4pt floor otherwise renders 0 and 1 identically, and
                    // an all-zero series as 14 stubs that read as real data.
                    let isToday = offset == visible.count - 1
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barFill(value: value, isToday: isToday))
                        .frame(height: value == 0
                               ? 2
                               : max(4, geo.size.height * CGFloat(value) / CGFloat(maxValue)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func barFill(value: Int, isToday: Bool) -> Color {
        if value == 0 {
            return isToday ? palette.accent.opacity(0.35) : palette.separator
        }
        return isToday ? palette.accent : palette.accent.opacity(0.55)
    }

    /// Keep each bar close to the iPhone pitch (14 bars in the compact
    /// column width). Wider graphs show more trailing days instead of
    /// stretching the same 14 bars.
    static func visibleSlice(values: [Int], width: CGFloat) -> [Int] {
        let days = HeroData.compactSparklineDays
        let pitch = LibraryHeroMetrics.compactColumnWidth / CGFloat(days)
        guard pitch > 0, width > 0 else {
            return Array(values.suffix(days))
        }
        let count = min(values.count, max(days, Int(width / pitch)))
        return Array(values.suffix(count))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Populated") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 680,
            deckCount: 7,
            streak: 36,
            recentDayTotals: HeroData.sampleDayTotals(),
            today: .sample
        )
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Populated — dark") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 680,
            deckCount: 7,
            streak: 36,
            recentDayTotals: HeroData.sampleDayTotals(),
            today: .sample
        )
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividDark)
    .preferredColorScheme(.dark)
}

#Preview("Regular — split layout") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 741,
            deckCount: 8,
            streak: 5,
            recentDayTotals: HeroData.sampleDayTotals(),
            today: .sample
        )
    )
    .padding(16)
    .frame(width: 720)
    .background(Color.gray.opacity(0.12))
    .environment(\.horizontalSizeClass, .regular)
    .environment(\.palette, .vividLight)
}

#Preview("Pane — wide and narrow") {
    VStack(spacing: 16) {
        LibraryHeroCard(
            data: HeroData(totalDue: 413, deckCount: 4, streak: 0,
                           recentDayTotals: HeroData.sampleDayTotals(), today: .sample),
            layout: .pane
        )
        .frame(width: 760)
        LibraryHeroCard(
            data: HeroData(totalDue: 413, deckCount: 4, streak: 0,
                           recentDayTotals: HeroData.sampleDayTotals(), today: .sample),
            layout: .pane
        )
        .frame(width: 520)
    }
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Zero due — unstudied today") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 0,
            deckCount: 4,
            streak: 12,
            recentDayTotals: HeroData.sampleDayTotals(),
            today: HeroTodayStats()
        )
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Streak zero — fresh chip") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 42,
            deckCount: 3,
            streak: 0,
            recentDayTotals: Array(repeating: 0, count: HeroData.sparklineCapacity),
            today: .sample
        )
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}
#endif
