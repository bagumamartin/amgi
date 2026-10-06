public import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import Charts
public import AnkiKit

public struct ButtonsChart: View {
    let buttons: ButtonsBuckets
    let period: StatsPeriod

    public init(buttons: ButtonsBuckets, period: StatsPeriod) {
        self.buttons = buttons
        self.period = period
    }

    @Environment(\.palette) private var palette
    @State private var selectedButton: String?

    private var buttonCounts: ButtonsBuckets.ButtonCounts {
        switch period {
        case .day, .week, .month: buttons.oneMonth
        case .threeMonths: buttons.threeMonths
        case .year: buttons.oneYear
        case .all: buttons.allTime
        }
    }

    private struct ButtonEntry: Identifiable {
        /// Stable across rebuilds — Charts diffs marks by `id`, and a fresh
        /// `UUID` would re-identify every bar on every `body` pass.
        var id: String { "\(cardType)-\(button)" }
        let button: String
        let cardType: String
        let count: Int
    }

    private var buttonLabels: [String] {
        [L10n.text("Again"), L10n.text("Hard"), L10n.text("Good"), L10n.text("Easy")]
    }
    private var cardTypes: [String] {
        [L10n.text("Learning"), L10n.text("Young"), L10n.text("Mature")]
    }

    private var entries: [ButtonEntry] {
        let bc = buttonCounts
        let sources: [(String, [Int])] = [
            (L10n.text("Learning"), bc.learning),
            (L10n.text("Young"), bc.young),
            (L10n.text("Mature"), bc.mature),
        ]
        var result: [ButtonEntry] = []
        for (typeName, counts) in sources {
            for (index, count) in counts.prefix(4).enumerated() {
                if count > 0 {
                    result.append(ButtonEntry(
                        button: buttonLabels[index],
                        cardType: typeName,
                        count: count
                    ))
                }
            }
        }
        return result
    }

    private var selectableButtons: [String] {
        Array(Set(entries.map(\.button))).sorted { lhs, rhs in
            let lhsIndex = buttonLabels.firstIndex(of: lhs) ?? .max
            let rhsIndex = buttonLabels.firstIndex(of: rhs) ?? .max
            return lhsIndex < rhsIndex
        }
    }

    private func nearestButton(proxy: ChartProxy, plotX: CGFloat) -> String? {
        guard let value: String = proxy.value(atX: plotX),
              selectableButtons.contains(value)
        else { return nil }
        return value
    }

    private func selectedCount(for button: String) -> Int {
        entries.filter { $0.button == button }.reduce(0) { $0 + $1.count }
    }

    public var body: some View {
        let entries = self.entries
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Answer Buttons").amgiFont(.bodyEmphasis)

                if entries.isEmpty {
                    Text("No button data").foregroundStyle(palette.textSecondary).frame(height: 180)
                } else {
                    Chart {
                        ForEach(entries) { entry in
                            BarMark(
                                x: .value("Button", entry.button),
                                y: .value("Count", entry.count)
                            )
                            .foregroundStyle(by: .value("Type", entry.cardType))
                        }

                        if let selectedButton, entries.contains(where: { $0.button == selectedButton }) {
                            RuleMark(x: .value("Selected Button", selectedButton))
                                .foregroundStyle(palette.textSecondary.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 0) {
                                    StatsChartTooltip(
                                        title: selectedButton,
                                        lines: [L10n.format("Answers: %lld", [selectedCount(for: selectedButton)])]
                                    )
                                }
                        }
                    }
                    .chartForegroundStyleScale([
                        L10n.text("Learning"): palette.cardStateNew,
                        L10n.text("Young"): palette.cardStateLearning,
                        L10n.text("Mature"): palette.cardStateMature,
                    ])
                    .statsChartXInspection(
                        values: selectableButtons,
                        selection: $selectedButton,
                        valueAtX: nearestButton,
                        xPosition: { button in
                            Double(buttonLabels.firstIndex(of: button) ?? 0)
                        },
                        accessibilityText: { button in
                            "\(button), \(L10n.format("Answers: %lld", [selectedCount(for: button)]))"
                        }
                    )
                    .frame(height: 180)
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ButtonsChart(buttons: .sample, period: .month)
        .padding()
}
#endif
