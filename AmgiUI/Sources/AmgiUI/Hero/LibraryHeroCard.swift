public import SwiftUI
import AmgiTheme

/// Library hero card. Built on `AmgiHeroSummary`. Wraps it to supply the
/// streak pill (top-right decoration slot), a quiet jump to the Study
/// desk (footer), and the 14-day sparkline (sidecar — stacked on
/// compact, beside copy on regular).
///
/// The due numeral and sparkline are collection facts. Starting today's
/// session belongs to Study, so this card does not play the queue.
public struct LibraryHeroCard: View {
    let data: HeroData
    let onOpenToday: () -> Void
    /// True while the review-history fetch that feeds `streak` and
    /// `last14Days` is still in flight. `totalDue` and `deckCount` come from
    /// the deck tree and are real immediately, so the card renders at once and
    /// only the history-derived decorations are shown as placeholders — a
    /// confident "0 day streak" that flips to 36 a second later is a worse
    /// answer than an obvious placeholder.
    let activityPending: Bool

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        data: HeroData,
        activityPending: Bool = false,
        onOpenToday: @escaping () -> Void
    ) {
        self.data = data
        self.activityPending = activityPending
        self.onOpenToday = onOpenToday
    }

    public var body: some View {
        AmgiHeroSummary(
            eyebrow: "Due today",
            bigNumber: "\(data.totalDue)",
            subtitle: subtitleText,
            decoration: {
                StreakBadge(days: data.streak)
                    .redacted(reason: activityPending ? .placeholder : [])
            },
            footer: { openTodayButton },
            sidecar: {
                sparkline
                    .redacted(reason: activityPending ? .placeholder : [])
            }
        )
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var openTodayButton: some View {
        Button(action: onOpenToday) {
            Text("Study today")
                .amgiFont(size: 16, weight: .semibold, relativeTo: .body)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.accent)
    }

    private var sparkline: some View {
        SparklineBars(values: data.recentDayTotals)
            .frame(height: isRegular ? nil : LibraryHeroMetrics.compactSparklineHeight)
    }

    private var subtitleText: String {
        "cards across \(data.deckCount) deck\(data.deckCount == 1 ? "" : "s")"
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
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        onOpenToday: {}
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
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        onOpenToday: {}
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
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        onOpenToday: {}
    )
    .padding(16)
    .frame(width: 720)
    .background(Color.gray.opacity(0.12))
    .environment(\.horizontalSizeClass, .regular)
    .environment(\.palette, .vividLight)
}

#Preview("Zero due — opens Today") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 0,
            deckCount: 4,
            streak: 12,
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        onOpenToday: {}
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
            recentDayTotals: Array(repeating: 0, count: HeroData.sparklineCapacity)
        ),
        onOpenToday: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}
#endif
