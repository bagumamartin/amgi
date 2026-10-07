public import SwiftUI
import AmgiTheme

/// Large circular progress visualization for the Study landing screen.
///
/// Three fixed concentric rings — New outside, Learning middle, Review
/// inside — so the colors and their positions stay learnable. Each ring
/// is a day-progress indicator: the bold arc is the completed share of
/// today (`reviewedToday / dueBaselineToday`, clamped to 1), revealed
/// clockwise from the top exactly like the ancestor's single segmented
/// sweep, glowing once the ring closes. The centre keeps the total due
/// count and today's completion percentage as the compact focal point.
public struct StudyDueRing: View {
    public let summary: StudySummaryData
    public var diameter: CGFloat
    /// Centre caption override. History spans pass their own tense
    /// ("Reviewed"); nil keeps the ring's Today/Due-now wording.
    public var centerCaption: String?
    /// Accessibility override for non-Today summaries whose counts
    /// would otherwise read as due today.
    public var centerAccessibility: String?
    /// History is a reconstruction, without a measurable completion denominator.
    public var showsProgress: Bool

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    @State private var displayedDue = 0

    private var ringSize: CGFloat { diameter }
    private var lineWidth: CGFloat { max(10, min(16, diameter * 0.075)) }
    private var ringSpacing: CGFloat { max(3, diameter * 0.02) }
    private var ringStep: CGFloat { lineWidth + ringSpacing }

    /// Completed share of the day. Single source of truth for every
    /// ring's fill and the centre percentage — per-category completion
    /// is not tracked, so no ring invents its own.
    private var progress: Double {
        showsProgress ? summary.todayProgressFraction : 0
    }

    /// Clear width inside the innermost stroke. Centre text is pinned
    /// to this so it never collides with the rings.
    private var innerClearWidth: CGFloat {
        max(44, ringSize - ringStep * 4 - lineWidth)
    }

    /// Caption under the percentage: what the ring fill and % mean.
    /// Plain word, no count — the numeral above already carries due.
    private var doneText: String {
        AmgiL10n.text("Done", locale: locale)
    }

    public init(
        summary: StudySummaryData,
        diameter: CGFloat = 168,
        centerCaption: String? = nil,
        centerAccessibility: String? = nil,
        showsProgress: Bool = true
    ) {
        self.summary = summary
        self.diameter = diameter
        self.centerCaption = centerCaption
        self.centerAccessibility = centerAccessibility
        self.showsProgress = showsProgress
    }

    public var body: some View {
        ZStack {
            categoryRings
            centerContent
        }
        .frame(width: ringSize, height: ringSize)
        .animation(AmgiMotion.standard, value: summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsProgress ? "Study progress" : "Historical cards")
        .accessibilityValue(centerAccessibility ?? accessibilitySummary)
        .accessibilityRepresentation {
            Image(systemName: "chart.circle.fill")
                .accessibilityLabel(showsProgress ? "Study progress" : "Historical cards")
                .accessibilityValue(centerAccessibility ?? accessibilitySummary)
        }
    }

    // MARK: - Category rings

    /// New, Learning, and Review are deliberately fixed from outside in so
    /// the colors and their positions remain learnable as counts change.
    private var categoryRings: some View {
        ZStack {
            categoryRing(
                color: palette.cardStateNew,
                diameter: ringSize
            )
            categoryRing(
                color: palette.cardStateLearning,
                diameter: ringSize - ringStep * 2
            )
            categoryRing(
                color: palette.cardStateReview,
                diameter: ringSize - ringStep * 4
            )
        }
        .shadow(
            color: palette.positive.opacity(progress * 0.45),
            radius: progress >= 1 ? 10 : 0
        )
    }

    private func categoryRing(color: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(
                    color.opacity(0.16),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)

            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            // Round sweep tip while the ring is open;
                            // butt joints close the full circle flush.
                            lineCap: progress < 1 ? .round : .butt
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - Centre text

    private var centerContent: some View {
        VStack(spacing: 2) {
            Text(centerCaption ?? AmgiL10n.text(summary.phase == .caughtUp ? "Today" : "DUE NOW", locale: locale))
                .textCase(.uppercase)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)

            Text("\(displayedDue)")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityHidden(true)

            if showsProgress {
                Text("\(summary.todayProgressPercent)%")
                    .amgiFont(.micro)
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityHidden(true)
                Text(doneText)
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: innerClearWidth)
        // Optical nudge: the short "Done" line leaves headroom below,
        // so the group sits slightly low and DUE NOW clears the top.
        .offset(y: 3)
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
        .accessibilityHidden(true)
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        let progress = AmgiL10n.format("%lld%% of today's goal complete", [summary.todayProgressPercent], locale: locale)
        guard summary.totalDue > 0 else {
            return "\(AmgiL10n.text("No cards due today", locale: locale)). \(progress)."
        }

        let due = summary.totalDue == 1
            ? AmgiL10n.text("1 card", locale: locale)
            : AmgiL10n.format("%lld cards", [summary.totalDue], locale: locale)
        return AmgiL10n.format(
            "%@ due today. %@ %lld, %@ %lld, %@ %lld. %@.",
            [
                due,
                AmgiL10n.text("New", locale: locale), summary.newCount,
                AmgiL10n.text("Learn", locale: locale), summary.learnCount,
                AmgiL10n.text("Review", locale: locale), summary.reviewCount,
                progress,
            ],
            locale: locale
        )
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
