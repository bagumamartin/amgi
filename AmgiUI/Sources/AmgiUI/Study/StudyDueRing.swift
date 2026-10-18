public import SwiftUI
import AmgiTheme

/// Large circular progress visualization for the Study landing screen.
///
/// Three fixed concentric rings — New outside, Learning middle, Review
/// inside — so the colors and their positions stay learnable. Each ring is
/// its own queue's day progress: the bold arc is the share of that queue's
/// start-of-day due that is no longer due (`StudySummaryData.queueProgress`),
/// revealed clockwise from the top, so the rings close independently and
/// each glows once it does. The centre keeps the total due count and the
/// whole day's completion percentage as the compact focal point.
///
/// `.segmented` draws the original single ring instead: one arc per queue,
/// sized by its share of what was due (`dueAtStart`, else the counts), in
/// the subtle tint until cleared. Each arc's cleared share fills in full
/// color from its own start, so review-ahead progress shows on future days,
/// where the mix is the information.
public struct StudyDueRing: View {
    public enum Style: Sendable {
        case concentric
        case segmented
    }

    public let summary: StudySummaryData
    public var diameter: CGFloat
    /// Centre caption override. History spans pass their own tense
    /// ("Reviewed"); nil keeps the ring's Today/Due-now wording.
    public var centerCaption: String?
    /// Accessibility override for non-Today summaries whose counts
    /// would otherwise read as due today.
    public var centerAccessibility: String?
    /// History is a reconstruction, without a measurable completion denominator.
    public var isLoading: Bool
    public var animatesChanges: Bool
    public var showsProgress: Bool
    public var style: Style

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    private var ringSize: CGFloat { diameter }
    private var lineWidth: CGFloat { max(10, min(16, diameter * 0.075)) }
    private var ringSpacing: CGFloat { max(3, diameter * 0.02) }
    private var ringStep: CGFloat { lineWidth + ringSpacing }

    /// Each queue's cleared share. Zero everywhere when the span has no
    /// measurable progress (multi-day history).
    private var queueProgress: (new: Double, learn: Double, review: Double) {
        showsProgress ? summary.queueProgress : (0, 0, 0)
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
        showsProgress: Bool = true,
        isLoading: Bool = false,
        animatesChanges: Bool = true,
        style: Style = .concentric
    ) {
        self.summary = summary
        self.diameter = diameter
        self.centerCaption = centerCaption
        self.centerAccessibility = centerAccessibility
        self.showsProgress = showsProgress
        self.isLoading = isLoading
        self.animatesChanges = animatesChanges
        self.style = style
    }

    public var body: some View {
        ZStack {
            switch style {
            case .concentric: categoryRings
            case .segmented: segmentedRing
            }
            centerContent
        }
        .frame(width: ringSize, height: ringSize)
        .animation(animatesChanges ? AmgiMotion.standard : nil, value: summary)
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
        let progress = queueProgress
        return ZStack {
            categoryRing(
                progress: progress.new,
                color: palette.cardStateNew,
                diameter: ringSize
            )
            categoryRing(
                progress: progress.learn,
                color: palette.cardStateLearning,
                diameter: ringSize - ringStep * 2
            )
            categoryRing(
                progress: progress.review,
                color: palette.cardStateReview,
                diameter: ringSize - ringStep * 4
            )
        }
    }

    private func categoryRing(progress: Double, color: Color, diameter: CGFloat) -> some View {
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
                    .shadow(color: color.opacity(0.5), radius: progress >= 1 ? 6 : 0)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - Segmented ring

    private struct SegmentRange {
        let color: Color
        let start: Double
        let end: Double
        /// Cleared share of this queue, 0…1.
        let progress: Double
    }

    /// The new/learning/review mix laid out clockwise from the top, with a
    /// small angular gap between non-zero segments.
    private var segments: [SegmentRange] {
        let due = summary.dueAtStart
        let progress = queueProgress
        let entries: [(Color, Int, Double)] = [
            (palette.cardStateNew, due?.new ?? summary.newCount, progress.new),
            (palette.cardStateLearning, due?.learn ?? summary.learnCount, progress.learn),
            (palette.cardStateReview, due?.review ?? summary.reviewCount, progress.review),
        ]
        let active = entries.filter { $0.1 > 0 }
        guard !active.isEmpty else { return [] }

        let activeTotal = active.reduce(0) { $0 + $1.1 }
        let gap = 0.008
        let totalGap = gap * Double(active.count - 1)

        var cursor = 0.0
        var segments: [SegmentRange] = []
        for (index, entry) in active.enumerated() {
            let span = Double(entry.1) / Double(activeTotal) * (1 - totalGap)
            segments.append(SegmentRange(color: entry.0, start: cursor, end: cursor + span, progress: entry.2))
            cursor += span
            if index < active.count - 1 { cursor += gap }
        }
        return segments
    }

    @ViewBuilder
    private var segmentedRing: some View {
        let segments = segments
        if segments.isEmpty {
            Circle()
                .stroke(palette.separator, lineWidth: lineWidth)
                .frame(width: ringSize, height: ringSize)
        } else {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(0.28)
                    .frame(width: ringSize, height: ringSize)
                if segment.progress > 0 {
                    Circle()
                        .trim(from: segment.start, to: segment.start + (segment.end - segment.start) * segment.progress)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .frame(width: ringSize, height: ringSize)
                }
            }
        }
    }

    // MARK: - Centre text

    private var centerContent: some View {
        VStack(spacing: 2) {
            Text(centerCaption ?? AmgiL10n.text(summary.phase == .caughtUp ? "Today" : "DUE NOW", locale: locale))
                .textCase(.uppercase)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)

            Text(isLoading ? "—" : "\(summary.totalDue)")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityHidden(true)

            if showsProgress, style == .concentric {
                Text(isLoading ? "—" : "\(summary.todayProgressPercent)%")
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
        dueBaselineToday: 305,
        dueAtStart: .init(new: 60, learn: 90, review: 205)
    ))
    .padding(32)
    .environment(\.palette, .vividLight)
}

#Preview("Future — segmented") {
    StudyDueRing(
        summary: StudySummaryData(
            totalDue: 64, newCount: 0, learnCount: 9, reviewCount: 55,
            todayLabel: "", subtitleLabel: "", deckCount: 0,
            dueAtStart: .init(new: 0, learn: 9, review: 80)
        ),
        centerCaption: "Due",
        style: .segmented
    )
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
        dueBaselineToday: 60,
        dueAtStart: .init(new: 10, learn: 8, review: 42)
    ))
    .padding(32)
    .background(Color.black)
    .environment(\.palette, .vividDark)
}
#endif
