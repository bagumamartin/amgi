public import SwiftUI
import AmgiTheme

/// Day hours, week bars, a month grid, or a year of mini calendars.
public struct StudySpanChart: View {
    let model: StudyChartModel
    let onSelectOffset: (Int) -> Void
    let onSelectMonth: (Int) -> Void
    let presentation: StudyDashboardPresentation

    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    public init(
        model: StudyChartModel,
        onSelectOffset: @escaping (Int) -> Void,
        onSelectMonth: @escaping (Int) -> Void = { _ in }
    ) {
        self.init(
            model: model,
            onSelectOffset: onSelectOffset,
            onSelectMonth: onSelectMonth,
            presentation: .compact
        )
    }

    init(
        model: StudyChartModel,
        onSelectOffset: @escaping (Int) -> Void,
        onSelectMonth: @escaping (Int) -> Void,
        presentation: StudyDashboardPresentation
    ) {
        self.model = model
        self.onSelectOffset = onSelectOffset
        self.onSelectMonth = onSelectMonth
        self.presentation = presentation
    }

    public var body: some View {
        switch model {
        case .bars(let columns):
            bars(columns)
        case .hours(let columns, let axis):
            hourBars(columns, axis: axis)
        case .forecastDay(let title, let count):
            forecastDay(title: title, count: count)
        case .month(let headers, let cells):
            month(headers: headers, cells: cells)
        case .year(let months):
            yearWall(months)
        }
    }

    private func forecastDay(title: String, count: Int) -> some View {
        VStack(spacing: AmgiSpacing.sm) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(count == 0 ? AmgiL10n.text("Nothing scheduled", locale: locale) : AmgiL10n.format("%lld scheduled", [count], locale: locale))
                .amgiFont(.bodyEmphasis, .monospacedDigits)
                .foregroundStyle(palette.textPrimary)
            Text(forecastDetail(title: title, count: count))
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(.horizontal, AmgiSpacing.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(forecastAccessibility(title: title, count: count))
    }

    private func forecastDetail(title: String, count: Int) -> String {
        let day = title.lowercased(with: locale)
        if count == 0 { return AmgiL10n.format("No cards are due on %@.", [day], locale: locale) }
        return AmgiL10n.format("Cards are scheduled for %@.", [day], locale: locale)
    }

    private func forecastAccessibility(title: String, count: Int) -> String {
        if count == 0 { return AmgiL10n.format("Nothing scheduled on %@", [title], locale: locale) }
        return AmgiL10n.format("%lld cards scheduled on %@", [count, title], locale: locale)
    }

    private func bars(_ columns: [StudyChartColumn]) -> some View {
        let peak = max(columns.map(\.value).max() ?? 0, 1)
        return VStack(spacing: headerGap) {
            HStack(spacing: 8) {
                ForEach(columns) { column in
                    headerLabel(column.label, emphasized: column.isSelected)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectOffset(column.offset) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(columns) { column in
                    Button {
                        onSelectOffset(column.offset)
                    } label: {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barFill(column))
                            .frame(height: barHeight(value: column.value, peak: peak))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibility(column))
                }
            }
            .frame(height: primaryBarAreaHeight, alignment: .bottom)
            HStack(spacing: 8) {
                ForEach(columns) { column in
                    headerLabel(column.axis, emphasized: column.isSelected)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectOffset(column.offset) }
                }
            }
        }
    }

    private func hourBars(_ columns: [StudyChartColumn], axis: [StudyAxisLabel]) -> some View {
        let peak = max(columns.map(\.value).max() ?? 0, 1)
        return VStack(spacing: headerGap) {
            HStack(spacing: 1) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    if index % 3 == 0 {
                        Text(column.label)
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: axisHeight)
                            .accessibilityHidden(true)
                    } else {
                        Color.clear
                            .frame(height: axisHeight)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(columns) { column in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(column.value > 0 ? palette.accent : palette.separator)
                        .frame(height: barHeight(value: column.value, peak: peak))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("\(column.label), \(column.value)")
                }
            }
            .frame(height: primaryBarAreaHeight, alignment: .bottom)
            hourScale(axis, slots: columns.count)
        }
    }

    /// Period labels are positioned by hour and clamped at the edges. This
    /// keeps words such as "Morning" and "Midnight" legible instead of
    /// clipping them inside a single 1/24-width chart slot.
    private func hourScale(_ marks: [StudyAxisLabel], slots: Int) -> some View {
        GeometryReader { proxy in
            let horizontalInset = min(44, proxy.size.width / 4)
            ZStack {
                Rectangle()
                    .fill(palette.separator.opacity(0.8))
                    .frame(height: 0.5)
                    .offset(y: 1)
                ForEach(marks.sorted { $0.slot < $1.slot }) { mark in
                    let rawX = CGFloat(mark.slot) / CGFloat(max(slots, 1)) * proxy.size.width
                    let x = min(max(rawX, horizontalInset), proxy.size.width - horizontalInset)
                    Text(mark.title)
                        .font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: x, y: axisHeight / 2)
                }
            }
        }
        .frame(height: axisHeight)
        .accessibilityHidden(true)
    }

    /// Same gap the month grid uses between its weekday letters and the days.
    private var headerGap: CGFloat {
        presentation == .compact || presentation == .medium ? 6 : 8
    }

    private func headerLabel(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(presentation == .compact || presentation == .medium ? .caption2 : .caption)
            .foregroundStyle(emphasized ? palette.textPrimary : palette.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var axisHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 28 : 18
    }

    private var primaryBarAreaHeight: CGFloat {
        switch presentation {
        case .compact: 72
        case .medium: 88
        case .regular: 88
        case .wide: 112
        }
    }

    private var monthCellHeight: CGFloat {
        presentation == .compact ? 40 : (presentation == .medium ? 42 : 44)
    }

    private var yearDayHeight: CGFloat {
        presentation == .compact ? 20 : (presentation == .medium ? 21 : 22)
    }

    private func barHeight(value: Int, peak: Int) -> CGFloat {
        if value <= 0 { return 2 }
        return max(8, (primaryBarAreaHeight - 6) * CGFloat(value) / CGFloat(peak))
    }

    private func barFill(_ column: StudyChartColumn) -> Color {
        if column.isSelected { return palette.accent }
        if column.isFuture { return palette.textTertiary.opacity(0.45) }
        if column.value == 0 { return palette.separator }
        return palette.accent.opacity(column.isToday ? 0.7 : 0.4)
    }

    private func accessibility(_ column: StudyChartColumn) -> String {
        let kind = column.isFuture ? "scheduled" : "reviewed"
        let selection = column.isSelected ? ", selected" : ""
        return "\(column.label), \(column.value) \(kind)\(selection)"
    }

    private func month(headers: [String], cells: [StudyMonthCell]) -> some View {
        let peak = max(cells.map(\.value).max() ?? 0, 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: headerGap) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                headerLabel(header, emphasized: false)
            }
            ForEach(cells) { cell in
                if let offset = cell.offset {
                    Button {
                        onSelectOffset(offset)
                    } label: {
                        monthCell(cell, peak: peak)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(monthAccessibility(cell))
                } else {
                    Color.clear.frame(height: monthCellHeight)
                }
            }
        }
    }

    private func monthCell(_ cell: StudyMonthCell, peak: Int) -> some View {
        let solid = isSolid(cell.value, maxCount: peak)
        return Text(cell.dayNumber)
            .amgiFont(.caption)
            .foregroundStyle(cell.isFuture ? palette.textPrimary : (solid ? Color.white : palette.textPrimary))
            .frame(maxWidth: .infinity)
            .frame(height: monthCellHeight)
            .background {
                Circle()
                    .fill(heatFill(cell.value, peak: peak, future: cell.isFuture))
                    .frame(width: 32, height: 32)
            }
            .overlay {
                if cell.isSelected || cell.isToday {
                    Circle()
                        .stroke(palette.accent, lineWidth: cell.isSelected ? 2 : 1.5)
                        .frame(width: 32, height: 32)
                }
            }
    }

    private func monthAccessibility(_ cell: StudyMonthCell) -> String {
        let kind = cell.isFuture ? "scheduled" : "reviewed"
        let selection = cell.isSelected ? ", selected" : ""
        return "Day \(cell.dayNumber), \(cell.value) \(kind)\(selection)"
    }

    private func yearWall(_ months: [StudyYearMonth]) -> some View {
        let peak = max(months.flatMap(\.cells).map(\.value).max() ?? 0, 1)
        let columnCount = presentation == .wide ? 3 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(months) { month in
                miniMonth(month, peak: peak)
            }
        }
    }

    private func miniMonth(_ month: StudyYearMonth, peak: Int) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                onSelectMonth(month.monthOffset)
            } label: {
                Text(month.name)
                    .amgiFont(.captionBold)
                    .foregroundStyle(month.isCurrent ? palette.accent : palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(month.cells) { cell in
                    if let offset = cell.offset {
                        Button {
                            onSelectOffset(offset)
                        } label: {
                            yearDay(cell, peak: peak)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(monthAccessibility(cell))
                    } else {
                        Color.clear.frame(height: yearDayHeight)
                    }
                }
            }
        }
    }

    private func yearDay(_ cell: StudyMonthCell, peak: Int) -> some View {
        let solid = isSolid(cell.value, maxCount: peak)
        return Text(cell.dayNumber)
            .amgiFont(.micro)
            .foregroundStyle(yearNumberColor(cell, solid: solid))
            .frame(maxWidth: .infinity)
            .frame(height: yearDayHeight)
            .background {
                if cell.isToday {
                    Circle().fill(palette.accent).frame(width: 16, height: 16)
                } else if cell.value > 0 {
                    Circle()
                        .fill(heatFill(cell.value, peak: peak, future: cell.isFuture))
                        .frame(width: 16, height: 16)
                }
            }
    }

    private func yearNumberColor(_ cell: StudyMonthCell, solid: Bool) -> Color {
        if cell.isFuture { return palette.textPrimary }
        if cell.isToday || solid { return .white }
        return palette.textPrimary
    }

    /// Past and today use the accent ramp. A future day is the same
    /// intensity, drawn in grey so a forecast does not look like a review.
    private func heatFill(_ value: Int, peak: Int, future: Bool) -> Color {
        guard value > 0 else { return .clear }
        if future {
            return HeatmapColorRamp.color(
                count: value,
                maxCount: peak,
                base: palette.textPrimary,
                empty: .clear
            )
        }
        return HeatmapColorRamp.color(count: value, maxCount: peak, palette: palette)
    }

    private func isSolid(_ value: Int, maxCount: Int) -> Bool {
        guard value > 0, maxCount > 0 else { return false }
        let normalised = Double(value) / Double(maxCount)
        return Int(normalised * 5) >= 4
    }
}
