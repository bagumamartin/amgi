public import SwiftUI
import AmgiTheme

/// A compact, actionable forecast for the next few Anki days. The forecast
/// deliberately stays separate from the activity chart: solid bars mean
/// scheduled work, while the historical chart represents answers already
/// recorded.
public struct StudyForecastCard: View {
    public let data: StudyForecastData
    public let onSelectDay: (Int) -> Void
    let presentation: StudyDashboardPresentation

    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    public init(
        data: StudyForecastData,
        onSelectDay: @escaping (Int) -> Void = { _ in }
    ) {
        self.init(
            data: data,
            onSelectDay: onSelectDay,
            presentation: .compact
        )
    }

    init(
        data: StudyForecastData,
        onSelectDay: @escaping (Int) -> Void,
        presentation: StudyDashboardPresentation
    ) {
        self.data = data
        self.onSelectDay = onSelectDay
        self.presentation = presentation
    }

    public var body: some View {
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(
                top: AmgiSpacing.lg,
                leading: AmgiSpacing.lg,
                bottom: AmgiSpacing.lg,
                trailing: AmgiSpacing.lg
            )
        ) {
            VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                header
                if data.days.isEmpty {
                    Text("Forecast unavailable")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                } else {
                    bars
                }
                metrics
                Text("Forecast assumes no intervening reviews.")
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AmgiSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan ahead")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.textPrimary)
                    .accessibilityHidden(true)
                Text("Next 7 Anki days")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: AmgiSpacing.sm)
            Image(systemName: "calendar.badge.clock")
                .amgiFont(.body)
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
        }
    }

    private var bars: some View {
        let peak = max(data.days.map(\.count).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: AmgiSpacing.sm) {
            ForEach(data.days) { day in
                Button {
                    onSelectDay(day.offset)
                } label: {
                    VStack(spacing: AmgiSpacing.xs) {
                        if day.count > 0 {
                            Text("\(day.count)")
                                .font(barLabelFont)
                                .monospacedDigit()
                                .foregroundStyle(palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Color.clear
                                .frame(height: 16)
                        }
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: barHeight(count: day.count, peak: peak))
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .top) {
                                if day.offset == 0 {
                                    Capsule()
                                        .fill(palette.accent)
                                        .frame(width: 18, height: 3)
                                        .offset(y: -3)
                                }
                            }
                        Text(compactBarLabel(day.label))
                            .font(barLabelFont)
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.accessibilityLabel)
                .accessibilityHint(day.offset == 0 ? AmgiL10n.text("Today", locale: locale) : AmgiL10n.text("Open this day", locale: locale))
            }
        }
        .frame(minHeight: forecastBarAreaHeight)
    }

    private var metrics: some View {
        VStack(spacing: AmgiSpacing.md) {
            ForEach(Array(metricRows.enumerated()), id: \.offset) { _, row in
                Canvas { context, size in
                    let columnGap = AmgiSpacing.md
                    let columnWidth = max(0, (size.width - columnGap) / 2)
                    for (index, metric) in row.enumerated() {
                        let rect = CGRect(
                            x: CGFloat(index) * (columnWidth + columnGap),
                            y: 0,
                            width: columnWidth,
                            height: size.height
                        )
                        let value = context.resolve(
                            Text(metric.value)
                                .font(.body)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(metric.color)
                        )
                        let title = context.resolve(
                            Text(metric.title)
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary)
                        )
                        let valueSize = value.measure(in: rect.size)
                        let titleSize = title.measure(in: rect.size)
                        let totalHeight = valueSize.height + 4 + titleSize.height
                        let y = rect.midY - totalHeight / 2
                        context.draw(value, at: CGPoint(x: rect.minX, y: y), anchor: .topLeading)
                        context.draw(
                            title,
                            at: CGPoint(x: rect.minX, y: y + valueSize.height + 4),
                            anchor: .topLeading
                        )
                    }
                }
                .frame(height: metricRowHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Forecast metrics")
        .accessibilityValue(metricsAccessibilityLabel)
        .accessibilityRepresentation {
            Image(systemName: "chart.bar.xaxis")
                .accessibilityLabel("Forecast metrics")
                .accessibilityValue(metricsAccessibilityLabel)
        }
    }

    private var metricRows: [[ForecastMetric]] {
        var metrics = [
            ForecastMetric(title: AmgiL10n.text("Tomorrow", locale: locale), value: "\(data.tomorrowDue)", color: palette.textPrimary),
            ForecastMetric(title: AmgiL10n.text("Daily Load", locale: locale), value: "\(data.dailyLoad)", color: palette.textPrimary),
        ]
        if data.hasBacklog {
            metrics.append(
                ForecastMetric(
                    title: AmgiL10n.text("Backlog", locale: locale),
                    value: data.backlogCount > 0 ? "\(data.backlogCount)" : "—",
                    color: palette.warning
                )
            )
        }
        if let unstable = data.unstableDueCount, data.fsrsEnabled {
            metrics.append(ForecastMetric(title: AmgiL10n.text("Unstable now", locale: locale), value: "\(unstable)", color: palette.danger))
        }
        return stride(from: 0, to: metrics.count, by: 2).map { start in
            Array(metrics[start..<min(start + 2, metrics.count)])
        }
    }

    private var metricRowHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 68 }
        return presentation == .compact ? 46 : 42
    }

    private var metricsAccessibilityLabel: String {
        var parts = [
            "\(AmgiL10n.text("Tomorrow", locale: locale)): \(data.tomorrowDue)",
            "\(AmgiL10n.text("Daily Load", locale: locale)): \(data.dailyLoad)",
        ]
        if data.hasBacklog {
            parts.append("\(AmgiL10n.text("Backlog", locale: locale)): \(data.backlogCount)")
        }
        if let unstable = data.unstableDueCount, data.fsrsEnabled {
            parts.append("\(AmgiL10n.text("Unstable now", locale: locale)): \(unstable)")
        }
        return parts.joined(separator: ", ")
    }

    private struct ForecastMetric {
        let title: String
        let value: String
        let color: Color
    }

    private var barLabelFont: Font {
        presentation == .compact || presentation == .medium ? .caption2 : .caption
    }

    private var forecastBarAreaHeight: CGFloat {
        switch presentation {
        case .compact: 126
        case .medium: 132
        case .regular: 138
        case .wide: 152
        }
    }

    private func compactBarLabel(_ label: String) -> String {
        (presentation == .compact || presentation == .medium) && label == AmgiL10n.text("Tomorrow", locale: locale) ? AmgiL10n.text("Tmrw", locale: locale) : label
    }

    private func barColor(for day: StudyForecastDay) -> Color {
        if day.offset == 0 { return palette.accent }
        return palette.accent.opacity(0.42)
    }

    private func barHeight(count: Int, peak: Int) -> CGFloat {
        guard count > 0 else { return 4 }
        let availableHeight = max(20, forecastBarAreaHeight - 48)
        return max(10, availableHeight * CGFloat(count) / CGFloat(peak))
    }
}

#if DEBUG
#Preview("Forecast") {
    StudyForecastCard(
        data: StudyForecastData(
            days: [
                StudyForecastDay(offset: 0, label: "Today", accessibilityLabel: "Today, 55 cards", count: 55),
                StudyForecastDay(offset: -1, label: "Tomorrow", accessibilityLabel: "Tomorrow, 40 cards", count: 40),
                StudyForecastDay(offset: -2, label: "Wed", accessibilityLabel: "Wednesday, 22 cards", count: 22),
                StudyForecastDay(offset: -3, label: "Thu", accessibilityLabel: "Thursday, 60 cards", count: 60),
                StudyForecastDay(offset: -4, label: "Fri", accessibilityLabel: "Friday, 18 cards", count: 18),
                StudyForecastDay(offset: -5, label: "Sat", accessibilityLabel: "Saturday, 8 cards", count: 8),
                StudyForecastDay(offset: -6, label: "Sun", accessibilityLabel: "Sunday, 12 cards", count: 12)
            ],
            tomorrowDue: 40,
            dailyLoad: 34,
            backlogCount: 18,
            hasBacklog: true,
            unstableDueCount: 7,
            fsrsEnabled: true
        )
    )
    .padding()
    .environment(\.palette, .vividLight)
}
#endif
