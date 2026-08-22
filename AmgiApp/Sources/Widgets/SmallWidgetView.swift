// AmgiApp/Sources/Widgets/SmallWidgetView.swift
import SwiftUI
import WidgetKit
import AmgiTheme

struct SmallWidgetView: View {
    @Environment(\.palette) private var palette
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(spacing: 0) {
            // Streak row
            HStack(spacing: 4) {
                Text("🔥")
                    .font(.system(size: 17))
                Text("\(snapshot.streak)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.warning)
                Text("day streak")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 6)

            // Shrunk Study Due ring with its center elements
            SmallDueRing(snapshot: snapshot)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "amgi://study"))
    }
}

/// Compact replica of the Study screen's `StudyDueRing`, drawn from the
/// widget snapshot. Segmented by the new/learning/review mix, with the day's
/// completion drawn as full-strength copies of those segments revealed up to
/// the completed fraction, and the center showing DUE NOW / numeral / deck
/// name / percentage.
struct SmallDueRing: View {
    @Environment(\.palette) private var palette
    let snapshot: WidgetSnapshot

    private let ringSize: CGFloat = 110
    private let lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            trackCircle
            ZStack {
                compositionArcs
                progressArc
            }
            centerContent
        }
        .frame(width: ringSize, height: ringSize)
    }

    // MARK: - Track

    private var trackCircle: some View {
        Circle()
            .stroke(palette.separator, lineWidth: lineWidth)
            .frame(width: ringSize, height: ringSize)
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
            (palette.cardStateNew, snapshot.newCount),
            (palette.cardStateLearning, snapshot.learnCount),
            (palette.cardStateReview, snapshot.reviewCount),
        ]
        let active = entries.filter { $0.1 > 0 }
        guard !active.isEmpty else { return [] }

        let activeTotal = active.reduce(0) { $0 + $1.1 }
        let gap = 0.008
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
    /// revealed clockwise up to the completed fraction, so hue flips land
    /// exactly on the dim backdrop's boundaries. With no composition (zero
    /// due) it falls back to the single positive sweep.
    private var progressArc: some View {
        let fraction = snapshot.todayProgressFraction
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
        .shadow(color: palette.positive.opacity(fraction * 0.45), radius: fraction >= 1 ? 8 : 0)
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
        VStack(spacing: 2) {
            Text("DUE NOW")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(palette.textSecondary)

            Text("\(snapshot.totalDue)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text(subline)
                .font(.system(size: 8))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: ringSize - lineWidth * 2 - 8)

            Capsule()
                .fill(palette.separator)
                .frame(width: 24, height: 1)

            Text("\(todayProgressPercent)% completed")
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
        }
    }

    private var subline: String {
        guard snapshot.totalDue > 0 else { return "Nothing due today" }
        return snapshot.deckName
    }

    private var todayProgressPercent: Int {
        Int((snapshot.todayProgressFraction * 100).rounded())
    }
}

#Preview(as: .systemSmall) {
    AmgiWidget()
} timeline: {
    WidgetEntry(date: Date(), snapshot: .placeholder)
}