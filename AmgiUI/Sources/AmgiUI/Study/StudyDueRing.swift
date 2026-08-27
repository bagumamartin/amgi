public import SwiftUI
import AmgiTheme

/// Large circular progress ring for the Study landing screen.
///
/// The ring is segmented by the live new/learning/review mix, with each arc
/// sized proportionally to the cards still due in that state. Today's
/// completion is drawn as full-strength copies of those same segments
/// revealed clockwise up to the completed fraction — single-state days stay
/// one hue throughout, and hue flips land exactly on the dimmed boundaries —
/// glowing once the ring closes, then resetting at Anki's next-day rollover.
///
/// Centre shows: "DUE NOW" caption / large due numeral / "across N decks"
/// subline / a subtle daily percentage separated by a small rule. Zero-due
/// state shows "0" with "Nothing due today".
public struct StudyDueRing: View {
    public let summary: StudySummaryData

    @Environment(\.palette) private var palette

    @State private var displayedDue = 0

    private let ringSize: CGFloat = 224
    private let lineWidth: CGFloat = 18

    public init(summary: StudySummaryData) {
        self.summary = summary
    }

    public var body: some View {
        ZStack {
            trackCircle
            ZStack {
                compositionArcs
                progressArc
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: summary)
            centerContent
        }
        .frame(width: ringSize, height: ringSize)
    }

    // MARK: - Track

    @ViewBuilder
    private var trackCircle: some View {
        // With a segmented composition, the dim arcs themselves are the
        // track — a full separator circle underneath would fill the segment
        // gaps with its own tone, erasing the boundaries. The plain circle
        // remains only for the zero-due fallback sweep.
        if compositionSegments.isEmpty {
            Circle()
                .stroke(palette.separator, lineWidth: lineWidth)
                .frame(width: ringSize, height: ringSize)
        }
    }

    // MARK: - Segments

    private struct SegmentRange {
        let color: Color
        let start: Double
        let end: Double
    }

    /// The live new/learning/review composition laid out clockwise from the
    /// top, with a small angular gap between non-zero segments.
    private var compositionSegments: [SegmentRange] {
        let entries: [(Color, Int)] = [
            (palette.cardStateNew, summary.newCount),
            (palette.cardStateLearning, summary.learnCount),
            (palette.cardStateReview, summary.reviewCount),
        ]
        let active = entries.filter { $0.1 > 0 }
        guard !active.isEmpty else { return [] }

        let activeTotal = active.reduce(0) { $0 + $1.1 }
        // Wide enough that the background showing through reads as a real
        // separator at ring size (≈8pt at 224pt diameter).
        let gap = 0.012
        let totalGap = gap * Double(active.count - 1)

        var cursor = 0.0
        var segments: [SegmentRange] = []
        for (index, entry) in active.enumerated() {
            let fraction = Double(entry.1) / Double(activeTotal)
            let span = fraction * (1 - totalGap)
            segments.append(SegmentRange(color: entry.0, start: cursor, end: cursor + span))
            cursor += span
            if index < active.count - 1 { cursor += gap }
        }
        return segments
    }

    private var compositionArcs: some View {
        ForEach(Array(compositionSegments.enumerated()), id: \.offset) { _, segment in
            Circle()
                .trim(from: segment.start, to: segment.end)
                .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .opacity(0.28)
        }
    }

    /// The day's progress: full-strength copies of the composition segments
    /// revealed clockwise up to the completed fraction, so each category
    /// fills in place and hue flips land exactly on the dim backdrop's
    /// boundaries. With no composition (zero due) it falls back to the
    /// single positive sweep, glowing once the day's baseline is cleared.
    private var progressArc: some View {
        let fraction = summary.todayProgressFraction
        let lit = litSegments(upTo: fraction)
        return Group {
            if compositionSegments.isEmpty {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(palette.positive, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ForEach(Array(lit.enumerated()), id: \.offset) { index, segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(
                            segment.color,
                            style: StrokeStyle(
                                lineWidth: lineWidth,
                                // Round sweep tip while the ring is open;
                                // butt joints keep lit/dim boundaries flush.
                                lineCap: index == lit.count - 1 && fraction < 1 ? .round : .butt
                            )
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .shadow(color: palette.positive.opacity(fraction * 0.45), radius: fraction >= 1 ? 10 : 0)
    }

    /// `compositionSegments` clamped to `fraction`: segments wholly beyond
    /// the completed point are dropped, the straddling one is trimmed.
    private func litSegments(upTo fraction: Double) -> [SegmentRange] {
        guard fraction > 0 else { return [] }
        var lit: [SegmentRange] = []
        for segment in compositionSegments where segment.start < fraction {
            lit.append(SegmentRange(color: segment.color, start: segment.start, end: min(segment.end, fraction)))
        }
        return lit
    }

    // MARK: - Centre text

    private var centerContent: some View {
        VStack(spacing: 3) {
            Text("DUE NOW")
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)

            Text("\(displayedDue)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.numericText())

            Text(sublineLabel)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: ringSize - lineWidth * 2 - 16)

            Capsule()
                .fill(palette.separator)
                .frame(width: 32, height: 1)

            Text("\(summary.todayProgressPercent)% completed")
                .amgiFont(.micro)
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)

            if let closeRingLabel {
                Text(closeRingLabel)
                    .amgiFont(.micro)
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                displayedDue = summary.totalDue
            }
        }
        .onChange(of: summary.totalDue) { _, newValue in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                displayedDue = newValue
            }
        }
    }

    private var sublineLabel: String {
        guard summary.totalDue > 0 else { return "Nothing due today" }
        let n = summary.deckCount
        return "across \(n) deck\(n == 1 ? "" : "s")"
    }

    private var closeRingLabel: String? {
        let remaining = summary.cardsRemainingToClose
        if remaining > 0 {
            return "\(remaining) to close the ring"
        } else if summary.reviewedToday > 0 {
            return "Ring closed"
        } else {
            return nil
        }
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
