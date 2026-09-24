public import SwiftUI
import AmgiTheme

/// A compact, actionable forecast for the next few Anki days. The forecast
/// deliberately stays separate from the activity chart: solid bars mean
/// scheduled work, while the historical chart represents answers already
/// recorded.
public struct StudyForecastCard: View {
    public let data: StudyForecastData
    public let onSelectDay: (Int) -> Void

    @Environment(\.palette) private var palette

    public init(
        data: StudyForecastData,
        onSelectDay: @escaping (Int) -> Void = { _ in }
    ) {
        self.data = data
        self.onSelectDay = onSelectDay
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
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AmgiSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan ahead")
                    .amgiFont(.cardTitle)
                    .foregroundStyle(palette.textPrimary)
                Text("Next 7 Anki days")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
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
                        Text(day.count > 0 ? "\(day.count)" : "")
                            .amgiFont(.micro, .monospacedDigits)
                            .foregroundStyle(palette.textSecondary)
                            .frame(height: 16)
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
                        Text(day.label)
                            .amgiFont(.micro)
                            .foregroundStyle(day.offset == 0 ? palette.textPrimary : palette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.accessibilityLabel)
                .accessibilityHint(day.offset == 0 ? "Today" : "Open this day")
            }
        }
        .frame(height: 126)
    }

    private var metrics: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: AmgiSpacing.md), GridItem(.flexible())],
            alignment: .leading,
            spacing: AmgiSpacing.md
        ) {
            metric("Tomorrow", value: "\(data.tomorrowDue)", color: palette.textPrimary)
            metric("Daily load", value: "\(data.dailyLoad)", color: palette.textPrimary)
            if data.hasBacklog {
                metric(
                    "Backlog",
                    value: data.backlogCount > 0 ? "\(data.backlogCount)" : "—",
                    color: palette.warning
                )
            }
            if let unstable = data.unstableDueCount, data.fsrsEnabled {
                metric("Unstable now", value: "\(unstable)", color: palette.danger)
            }
        }
    }

    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
            Text(value)
                .amgiFont(.bodyEmphasis, .monospacedDigits)
                .foregroundStyle(color)
            Text(title)
                .amgiFont(.micro)
                .foregroundStyle(palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barColor(for day: StudyForecastDay) -> Color {
        if day.offset == 0 { return palette.accent }
        return palette.accent.opacity(0.42)
    }

    private func barHeight(count: Int, peak: Int) -> CGFloat {
        guard count > 0 else { return 4 }
        return max(10, 76 * CGFloat(count) / CGFloat(peak))
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
