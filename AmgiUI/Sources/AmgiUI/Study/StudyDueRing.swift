public import SwiftUI
import AmgiTheme

/// Large circular progress visualization for the Study landing screen.
///
/// Three fixed concentric rings keep the live new/learning/review mix
/// readable at a glance. Each category owns one ring: its colored arc is
/// the share of the live queue in that state, sitting on a dim track in the
/// same category color. The centre keeps the total due count and today's
/// completion percentage as the compact focal point.
public struct StudyDueRing: View {
    public let summary: StudySummaryData
    public var diameter: CGFloat

    @Environment(\.palette) private var palette

    @State private var displayedDue = 0

    private var ringSize: CGFloat { diameter }
    private var lineWidth: CGFloat { max(10, min(16, diameter * 0.075)) }
    private var ringSpacing: CGFloat { max(3, diameter * 0.02) }
    private var ringStep: CGFloat { lineWidth + ringSpacing }

    private var categoryTotal: Int {
        max(0, summary.newCount + summary.learnCount + summary.reviewCount)
    }

    public init(summary: StudySummaryData, diameter: CGFloat = 168) {
        self.summary = summary
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            categoryRings
            centerContent
        }
        .frame(width: ringSize, height: ringSize)
        .animation(AmgiMotion.standard, value: summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Category rings

    /// New, Learning, and Review are deliberately fixed from outside in so
    /// the colors and their positions remain learnable as counts change.
    private var categoryRings: some View {
        ZStack {
            categoryRing(
                count: summary.newCount,
                color: palette.cardStateNew,
                diameter: ringSize
            )
            categoryRing(
                count: summary.learnCount,
                color: palette.cardStateLearning,
                diameter: ringSize - ringStep * 2
            )
            categoryRing(
                count: summary.reviewCount,
                color: palette.cardStateReview,
                diameter: ringSize - ringStep * 4
            )
        }
    }

    private func categoryRing(count: Int, color: Color, diameter: CGFloat) -> some View {
        let fraction = categoryFraction(for: count)
        return ZStack {
            Circle()
                .stroke(
                    color.opacity(0.16),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)

            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func categoryFraction(for count: Int) -> Double {
        guard categoryTotal > 0 else { return 0 }
        return min(1, max(0, Double(count) / Double(categoryTotal)))
    }

    // MARK: - Centre text

    private var centerContent: some View {
        VStack(spacing: 2) {
            Text(summary.phase == .caughtUp ? "TODAY" : "DUE NOW")
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)

            Text("\(displayedDue)")
                .font(.system(size: diameter >= 190 ? 44 : 34, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.numericText())

            Text("\(summary.todayProgressPercent)%")
                .amgiFont(.micro)
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
            progressIndicator
        }
        .onAppear {
            withAnimation(AmgiMotion.standard) {
                displayedDue = summary.totalDue
            }
        }
        .onChange(of: summary.totalDue) { _, newValue in
            withAnimation(AmgiMotion.standard) {
                displayedDue = newValue
            }
        }
    }

    private var progressIndicator: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.separator.opacity(0.55))
                Capsule()
                    .fill(palette.accent)
                    .frame(width: proxy.size.width * summary.todayProgressFraction)
            }
        }
        .frame(width: min(max(diameter * 0.36, 48), 82), height: 4)
        .accessibilityHidden(true)
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        let progress = "\(summary.todayProgressPercent)% of today's goal complete"
        guard summary.totalDue > 0 else {
            return "No cards due today. \(progress)."
        }

        let due = summary.totalDue == 1 ? "1 card" : "\(summary.totalDue) cards"
        return "\(due) due today. New \(summary.newCount), learning \(summary.learnCount), review \(summary.reviewCount). \(progress)."
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Busy day") {
    StudyDueRing(summary: StudySummaryData(
        totalDue: 187,
        newCount: 40,
        learnCount: 72,
        reviewCount: 75,
        todayLabel: "Today",
        subtitleLabel: "Wednesday · 4 decks due",
        deckCount: 4,
        reviewedToday: 118,
        dueBaselineToday: 305
    ))
    .padding(32)
    .environment(\.palette, .vividLight)
}

#Preview("All done") {
    StudyDueRing(summary: StudySummaryData(
        totalDue: 0,
        newCount: 0,
        learnCount: 0,
        reviewCount: 0,
        todayLabel: "Today",
        subtitleLabel: "Wednesday",
        deckCount: 0
    ))
    .padding(32)
    .environment(\.palette, .vividLight)
}

#Preview("Dark — busy") {
    StudyDueRing(summary: StudySummaryData(
        totalDue: 42,
        newCount: 10,
        learnCount: 8,
        reviewCount: 24,
        todayLabel: "Today",
        subtitleLabel: "Thursday · 3 decks due",
        deckCount: 3,
        reviewedToday: 18,
        dueBaselineToday: 60
    ))
    .padding(32)
    .background(Color.black)
    .environment(\.palette, .vividDark)
}
#endif
