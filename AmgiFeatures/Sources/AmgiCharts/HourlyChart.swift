public import SwiftUI
import AmgiTheme
import AmgiUI
import Charts
public import AnkiKit

public struct HourlyChart: View {
    let hours: HoursBuckets
    let period: StatsPeriod

    public init(hours: HoursBuckets, period: StatsPeriod) {
        self.hours = hours
        self.period = period
    }

    @Environment(\.palette) private var palette
    @State private var selectedHour: Int?

    private var hourData: [HoursBuckets.Hour] {
        switch period {
        case .day, .week, .month: hours.oneMonth
        case .threeMonths: hours.threeMonths
        case .year: hours.oneYear
        case .all: hours.allTime
        }
    }

    private struct HourEntry: Identifiable {
        let id: Int
        let hour: Int
        let total: Int
        let correctPct: Double
    }

    private var entries: [HourEntry] {
        guard hourData.count == 24 else {
            return (0..<24).map { HourEntry(id: $0, hour: $0, total: 0, correctPct: 0) }
        }
        return hourData.enumerated().map { index, hour in
            let pct = hour.total > 0 ? Double(hour.correct) / Double(hour.total) * 100 : 0
            return HourEntry(id: index, hour: index, total: Int(hour.total), correctPct: pct)
        }
    }

    private var selectableHours: [Int] { Array(0..<24) }

    private func nearestHour(proxy: ChartProxy, plotX: CGFloat) -> Int? {
        guard let value: Double = proxy.value(atX: plotX) else { return nil }
        return min(23, max(0, Int(value.rounded())))
    }

    private func selectedEntry(for hour: Int) -> HourEntry? {
        entries.first(where: { $0.hour == hour })
    }

    public var body: some View {
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hourly Breakdown").amgiFont(.bodyEmphasis)

                if entries.allSatisfy({ $0.total == 0 }) {
                    Text("No review data").foregroundStyle(palette.textSecondary).frame(height: 180)
                } else {
                    Chart {
                        ForEach(entries) { entry in
                            BarMark(
                                x: .value("Hour", entry.hour),
                                y: .value("Reviews", entry.total)
                            )
                            .foregroundStyle(palette.accent.gradient)
                        }

                        if let selectedHour, let selected = selectedEntry(for: selectedHour) {
                            RuleMark(x: .value("Selected Hour", selectedHour))
                                .foregroundStyle(palette.textSecondary.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 0) {
                                    StatsChartTooltip(
                                        title: formatHour(selected.hour),
                                        lines: [
                                            "Reviews: \(selected.total)",
                                            String(format: "Correct: %.0f%%", selected.correctPct),
                                        ]
                                    )
                                }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 4, 8, 12, 16, 20]) { value in
                            AxisGridLine()
                            if let h = value.as(Int.self) {
                                AxisValueLabel(formatHour(h))
                            }
                        }
                    }
                    .chartXScale(domain: 0...23)
                    .statsChartXInspection(
                        values: selectableHours,
                        selection: $selectedHour,
                        valueAtX: nearestHour,
                        xPosition: { Double($0) },
                        accessibilityText: { hour in
                            guard let selected = selectedEntry(for: hour) else { return formatHour(hour) }
                            return "\(formatHour(hour)), Reviews: \(selected.total), Correct: \(Int(selected.correctPct.rounded()))%"
                        }
                    )
                    .frame(height: 150)

                    Chart {
                        ForEach(entries) { entry in
                            LineMark(
                                x: .value("Hour", entry.hour),
                                y: .value("Correct %", entry.correctPct)
                            )
                            .foregroundStyle(palette.positive)
                            .interpolationMethod(.catmullRom)

                            AreaMark(
                                x: .value("Hour", entry.hour),
                                y: .value("Correct %", entry.correctPct)
                            )
                            .foregroundStyle(palette.positive.opacity(0.1))
                            .interpolationMethod(.catmullRom)
                        }

                        if let selectedHour {
                            RuleMark(x: .value("Selected Hour", selectedHour))
                                .foregroundStyle(palette.textSecondary.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 4, 8, 12, 16, 20]) { value in
                            AxisGridLine()
                            if let h = value.as(Int.self) {
                                AxisValueLabel(formatHour(h))
                            }
                        }
                    }
                    .chartXScale(domain: 0...23)
                    .chartYScale(domain: 0...100)
                    .chartYAxisLabel("Correct %")
                    .frame(height: 100)
                }
            }
        }
    }
}

private extension HourlyChart {
    func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HourlyChart(hours: .sample, period: .month)
        .padding()
}
#endif
