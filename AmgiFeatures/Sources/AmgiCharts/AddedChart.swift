public import SwiftUI
import AmgiTheme
import AmgiUI
import Charts
public import AnkiKit

public struct AddedChart: View {
    let added: AddedSeries
    let period: StatsPeriod

    public init(added: AddedSeries, period: StatsPeriod) {
        self.added = added
        self.period = period
    }

    @Environment(\.palette) private var palette
    @State private var selectedDay: Int?

    private var filteredData: [(day: Int, count: Int)] {
        let maxDay = period.days
        return added.added
            .compactMap { (dayOffset, count) -> (day: Int, count: Int)? in
                let day = Int(dayOffset)
                guard day <= 0, abs(day) <= maxDay else { return nil }
                return (day: day, count: Int(count))
            }
            .sorted(by: { $0.day < $1.day })
    }

    private var totalAdded: Int { filteredData.reduce(0) { $0 + $1.count } }
    private var avgPerDay: Double {
        guard !filteredData.isEmpty else { return 0 }
        let days = Set(filteredData.map(\.day)).count
        return Double(totalAdded) / Double(max(days, 1))
    }

    private var selectableDays: [Int] { filteredData.map(\.day) }

    private func nearestDay(proxy: ChartProxy, plotX: CGFloat) -> Int? {
        guard let value: Double = proxy.value(atX: plotX) else { return nil }
        return selectableDays.min { abs(Double($0) - value) < abs(Double($1) - value) }
    }

    private func selectedCount(for day: Int) -> Int {
        filteredData.first(where: { $0.day == day })?.count ?? 0
    }

    private func selectedAccessibilityText(for day: Int) -> String {
        "\(statsChartDayTitle(day)), Cards added: \(selectedCount(for: day))"
    }

    public var body: some View {
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cards Added").amgiFont(.bodyEmphasis)

                if filteredData.isEmpty {
                    Text("No cards added").foregroundStyle(palette.textSecondary).frame(height: 180)
                } else {
                    Chart {
                        ForEach(filteredData, id: \.day) { item in
                            BarMark(
                                x: .value("Day", item.day),
                                y: .value("Cards", item.count)
                            )
                            .foregroundStyle(palette.accent.gradient)
                        }

                        if let selectedDay, filteredData.contains(where: { $0.day == selectedDay }) {
                            RuleMark(x: .value("Selected Day", selectedDay))
                                .foregroundStyle(palette.textSecondary.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 0) {
                                    StatsChartTooltip(
                                        title: statsChartDayTitle(selectedDay),
                                        lines: ["Cards added: \(selectedCount(for: selectedDay))"]
                                    )
                                }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .statsChartXInspection(
                        values: selectableDays,
                        selection: $selectedDay,
                        valueAtX: nearestDay,
                        xPosition: { Double($0) },
                        accessibilityText: selectedAccessibilityText
                    )
                    .frame(height: 180)
                }

                HStack(spacing: 16) {
                    footerItem("Total", value: "\(totalAdded)")
                    footerItem("Avg/day", value: String(format: "%.1f", avgPerDay))
                }
            }
        }
    }
}

private extension AddedChart {
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
    AddedChart(added: .sample, period: .month)
        .padding()
}
#endif
