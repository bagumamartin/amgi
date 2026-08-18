public import SwiftUI
import AmgiTheme

/// Library hero card. Built on `AmgiHeroSummary`. Wraps it to supply the
/// streak pill (top-right decoration slot), the CTA (footer), and the
/// 14-day sparkline (sidecar — stacked on compact, beside copy on regular).
///
/// `data.totalDue == 0` disables the CTA; the rest still renders so
/// the user sees their streak + sparkline.
public struct LibraryHeroCard: View {
    let data: HeroData
    let onStartReview: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(data: HeroData, onStartReview: @escaping () -> Void) {
        self.data = data
        self.onStartReview = onStartReview
    }

    public var body: some View {
        AmgiHeroSummary(
            eyebrow: "Due today",
            bigNumber: "\(data.totalDue)",
            subtitle: subtitleText,
            background: heroGradient,
            decoration: { StreakBadge(days: data.streak) },
            footer: { startReviewButton },
            sidecar: { sparkline }
        )
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var startReviewButton: some View {
        Button(action: onStartReview) {
            Label("Start today's review", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.white.opacity(0.22))
        .foregroundStyle(.white)
        .disabled(data.totalDue == 0)
    }

    private var sparkline: some View {
        SparklineBars(values: data.recentDayTotals)
            .frame(height: isRegular ? nil : 36)
    }

    private var subtitleText: String {
        "cards across \(data.deckCount) deck\(data.deckCount == 1 ? "" : "s")"
    }

    private var heroGradient: AmgiCardBackground {
        .gradient(
            start: palette.accent,
            end: Color(red: 0.37, green: 0.36, blue: 0.91), // #5E5CE6 Apple indigo
            angle: .degrees(155)
        )
    }
}

// MARK: - Streak pill

private struct StreakBadge: View {
    let days: Int

    var body: some View {
        if days > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("\(days)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(.white.opacity(0.22), in: Capsule())
        }
    }
}

// MARK: - 14-day sparkline

private struct SparklineBars: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let visible = Self.visibleSlice(values: values, width: geo.size.width)
            let maxValue = max(visible.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white.opacity(0.55))
                        .frame(height: max(4, geo.size.height * CGFloat(value) / CGFloat(maxValue)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
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
        onStartReview: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Regular — split layout") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 741,
            deckCount: 8,
            streak: 5,
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        onStartReview: {}
    )
    .padding(16)
    .frame(width: 720)
    .background(Color.gray.opacity(0.12))
    .environment(\.horizontalSizeClass, .regular)
    .environment(\.palette, .vividLight)
}

#Preview("Zero due — CTA disabled") {
    LibraryHeroCard(
        data: HeroData(
            totalDue: 0,
            deckCount: 4,
            streak: 12,
            recentDayTotals: HeroData.sampleDayTotals()
        ),
        onStartReview: {}
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
        onStartReview: {}
    )
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}
#endif
