public import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import Charts
public import AnkiKit

public struct FutureDueChart: View {
    let futureDue: FutureDueSeries
    let period: StatsPeriod

    public init(futureDue: FutureDueSeries, period: StatsPeriod) {
        self.futureDue = futureDue
        self.period = period
    }

    @Environment(\.palette) private var palette
    @State private var includeBacklog = false
    @State private var selectedDay: Int?

    private var filteredData: [(day: Int, count: Int)] {
        let maxDay = period.days
        return futureDue.futureDue
            .compactMap { (dayOffset, count) -> (day: Int, count: Int)? in
                let day = Int(dayOffset)
                if !includeBacklog && day < 0 { return nil }
                guard day < maxDay else { return nil }
                return (day: day, count: Int(count))
            }
            .sorted(by: { $0.day < $1.day })
    }

    private func totalDue(_ data: [(day: Int, count: Int)]) -> Int {
        data.reduce(0) { $0 + $1.count }
    }

    private func dueTomorrow(_ data: [(day: Int, count: Int)]) -> Int {
        data.first(where: { $0.day == 1 })?.count ?? 0
    }

    private func avgPerDay(_ data: [(day: Int, count: Int)]) -> Double {
        let positiveDays = data.filter { $0.day >= 0 }
        guard !positiveDays.isEmpty else { return 0 }
        let maxOffset = positiveDays.map(\.day).max() ?? 1
        return Double(positiveDays.reduce(0) { $0 + $1.count }) / Double(max(maxOffset, 1))
    }

    private func nearestDay(proxy: ChartProxy, plotX: CGFloat, values: [Int]) -> Int? {
        guard let value: Double = proxy.value(atX: plotX) else { return nil }
        return values.min { abs(Double($0) - value) < abs(Double($1) - value) }
    }

    private func selectedCount(for day: Int, in data: [(day: Int, count: Int)]) -> Int {
        data.first(where: { $0.day == day })?.count ?? 0
    }

    public var body: some View {
        // Built once per pass and threaded through — reading the computed
        // `filteredData` from each call site re-ran the compactMap + sort five
        // times per `body`.
        let filteredData = self.filteredData
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Future Due").amgiFont(.bodyEmphasis)

                if filteredData.isEmpty {
                    Text("No cards due").foregroundStyle(palette.textSecondary).frame(height: 180)
                } else {
                    Chart {
                        ForEach(filteredData, id: \.day) { item in
                            BarMark(
                                x: .value("Day", item.day),
                                y: .value("Cards", item.count)
                            )
                            .foregroundStyle(item.day < 0 ? palette.danger.gradient : palette.accent.gradient)
                        }

                        if let selectedDay, filteredData.contains(where: { $0.day == selectedDay }) {
                            RuleMark(x: .value("Selected Day", selectedDay))
                                .foregroundStyle(palette.textSecondary.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 0) {
                                    StatsChartTooltip(
                                        title: statsChartDayTitle(selectedDay),
                                        lines: [
                                            L10n.format("Cards due: %lld", [selectedCount(for: selectedDay, in: filteredData)]),
                                        ] + (selectedDay < 0 ? [L10n.text("Backlog")] : [])
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
                        values: filteredData.map(\.day),
                        selection: $selectedDay,
                        valueAtX: { proxy, x in
                            nearestDay(proxy: proxy, plotX: x, values: filteredData.map(\.day))
                        },
                        xPosition: { Double($0) },
                        accessibilityText: { day in
                            "\(statsChartDayTitle(day)), \(L10n.format("Cards due: %lld", [selectedCount(for: day, in: filteredData)]))"
                        }
                    )
                    .frame(height: 180)
                }

                if futureDue.haveBacklog {
                    Toggle(L10n.text("Include Backlog"), isOn: Binding(
                        get: { includeBacklog },
                        set: { newValue in
                            includeBacklog = newValue
                            if !newValue { selectedDay = nil }
                        }
                    ))
                    .amgiFont(.caption)
                }

                HStack(spacing: 16) {
                    footerItem(L10n.text("Total"), value: "\(totalDue(filteredData))")
                    footerItem(L10n.text("Avg/day"), value: String(format: "%.1f", avgPerDay(filteredData)))
                    footerItem(L10n.text("Tomorrow"), value: "\(dueTomorrow(filteredData))")
                    footerItem(L10n.text("Daily Load"), value: "\(futureDue.dailyLoad)")
                }
            }
        }
    }
}

private extension FutureDueChart {
    func footerItem(_ label: String, value: String) -> some View {
        VStack(spacing: AmgiSpacing.xxs) {
            Text(value).amgiFont(.captionBold).monospacedDigit()
            Text(label).amgiFont(.micro).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    FutureDueChart(futureDue: .sample, period: .month)
        .padding()
}
#endif
