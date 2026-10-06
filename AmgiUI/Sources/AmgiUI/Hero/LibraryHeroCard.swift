public import SwiftUI
import AmgiTheme

/// Library hero card. Built on `AmgiHeroSummary`. Wraps it to supply the
/// streak pill (top-right decoration slot), today's review stats (footer
/// strip) and the 14-day sparkline (sidecar — stacked on compact, beside
/// copy on regular).
///
/// The due numeral and sparkline are collection facts. Starting today's
/// session belongs to Study, so this card does not play the queue.
public struct LibraryHeroCard: View {
    let data: HeroData
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

    public init(
        data: HeroData,
        activityPending: Bool = false
    ) {
        self.data = data
        self.activityPending = activityPending
    }

    public var body: some View {
        AmgiHeroSummary(
            header: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(AmgiL10n.text("Due today", locale: locale).uppercased(with: locale))
                            .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                            .foregroundStyle(palette.textTertiary)
                        Spacer(minLength: 12)
                        StreakBadge(days: data.streak)
                            .redacted(reason: activityPending ? .placeholder : [])
                    }
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(data.totalDue)")
                                .amgiFont(size: 56, weight: .bold, tracking: -1.2, relativeTo: .largeTitle)
                                .foregroundStyle(palette.textPrimary)
                            Text(subtitleText)
                                .amgiFont(size: 15, weight: .regular, relativeTo: .subheadline)
                                .foregroundStyle(palette.textSecondary)
                        }
                        .layoutPriority(1)
                        VStack(spacing: 8) {
                            HeroHeaderStatTiles(today: data.today ?? HeroTodayStats())
                                .redacted(reason: activityPending ? .placeholder : [])
                            paceTile
                        }
                    }
                }
            },
            footer: {
                HeroRetentionTile(today: data.today ?? HeroTodayStats())
                    .redacted(reason: activityPending ? .placeholder : [])
            },
            sidecar: {
                sparkline
                    .redacted(reason: activityPending ? .placeholder : [])
            }
        )
    }

    private var paceTile: some View {
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
            horizontalPadding: 4
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

// MARK: - Streak pill

private struct StreakBadge: View {
    let days: Int

    @Environment(\.palette) private var palette

    var body: some View {
        if days > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .amgiFont(size: 12, weight: .bold, relativeTo: .footnote)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(palette.warning)
                Text("\(days)")
                    .amgiFont(size: 14, weight: .semibold, relativeTo: .footnote)
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.accentSoft, in: Capsule())
        }
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

#Preview("Streak zero — badge hidden") {
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
