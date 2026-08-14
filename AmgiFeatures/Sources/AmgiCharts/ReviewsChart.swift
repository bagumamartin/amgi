public import SwiftUI
import AmgiTheme
import AmgiUI
import Charts
public import AnkiKit

public struct ReviewsChart: View {
    let reviews: ReviewCountsAndTimes
    let period: StatsPeriod

    public init(reviews: ReviewCountsAndTimes, period: StatsPeriod) {
        self.reviews = reviews
        self.period = period
    }

    @Environment(\.palette) private var palette

    private struct ReviewEntry: Identifiable {
        /// Number of review types — the stride `id` packs `day` by.
        static let typeCount = 5

        /// Stable across rebuilds: `(day, typeIndex)` is unique because
        /// `typeIndex` is always less than the stride, and Charts diffs marks
        /// by `id`. A fresh `UUID` here would give every mark a new identity on
        /// every `body` pass, forcing a full re-layout instead of an update.
        var id: Int { day * Self.typeCount + typeIndex }
        let day: Int
        let typeIndex: Int
        let type: String
        let count: Int
        let color: Color
    }

    private var entries: [ReviewEntry] {
        let maxDay = period.days
        let types: [(String, KeyPath<ReviewCountsAndTimes.Reviews, Int>, Color)] = [
            ("Learn", \.learn, palette.cardStateNew),
            ("Relearn", \.relearn, palette.cardStateRelearn),
            ("Young", \.young, palette.cardStateLearning),
            ("Mature", \.mature, palette.cardStateMature),
            ("Filtered", \.filtered, palette.textTertiary),
        ]
        var result: [ReviewEntry] = []
        for (day, rev) in reviews.count {
            guard day <= 0, abs(day) <= maxDay else { continue }
            for (typeIndex, (name, kp, color)) in types.enumerated() {
                let value = rev[keyPath: kp]
                if value > 0 {
                    result.append(ReviewEntry(
                        day: day, typeIndex: typeIndex,
                        type: name, count: value, color: color
                    ))
                }
            }
        }
        return result.sorted(by: { $0.day < $1.day })
    }

    private func totalReviews(_ entries: [ReviewEntry]) -> Int {
        entries.reduce(0) { $0 + $1.count }
    }

    private func avgPerDay(_ entries: [ReviewEntry]) -> Double {
        guard !entries.isEmpty else { return 0 }
        let uniqueDays = Set(entries.map(\.day)).count
        return Double(totalReviews(entries)) / Double(max(uniqueDays, 1))
    }

    public var body: some View {
        // Built once per pass and threaded through. Reading the computed
        // `entries` from each call site instead rebuilt the whole series six
        // times per `body` — once for `isEmpty`, once for the chart, and four
        // more inside the two footer figures.
        let entries = self.entries
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reviews").amgiFont(.bodyEmphasis)

                if entries.isEmpty {
                    Text("No review data").foregroundStyle(palette.textSecondary).frame(height: 180)
                } else {
                    Chart(entries) { entry in
                        BarMark(
                            x: .value("Day", entry.day),
                            y: .value("Count", entry.count)
                        )
                        .foregroundStyle(by: .value("Type", entry.type))
                    }
                    .chartForegroundStyleScale([
                        "Learn": palette.cardStateNew,
                        "Relearn": palette.cardStateRelearn,
                        "Young": palette.cardStateLearning,
                        "Mature": palette.cardStateMature,
                        "Filtered": palette.textTertiary,
                    ])
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 180)
                }

                HStack(spacing: 16) {
                    footerItem("Total", value: "\(totalReviews(entries))")
                    footerItem("Avg/day", value: String(format: "%.1f", avgPerDay(entries)))
                }
            }
        }
    }
}

private extension ReviewsChart {
    func footerItem(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).amgiFont(.captionBold).monospacedDigit()
            Text(label).amgiFont(.caption).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ReviewsChart(reviews: .sampleYear, period: .month)
        .padding()
}
#endif
