public import SwiftUI
import AmgiTheme

/// Day hours, week bars, a month grid, or a year of mini calendars.
public struct StudySpanChart: View {
    let model: StudyChartModel
    let onSelectOffset: (Int) -> Void
    let onSelectMonth: (Int) -> Void

    @Environment(\.palette) private var palette

    public init(
        model: StudyChartModel,
        onSelectOffset: @escaping (Int) -> Void,
        onSelectMonth: @escaping (Int) -> Void = { _ in }
    ) {
        self.model = model
        self.onSelectOffset = onSelectOffset
        self.onSelectMonth = onSelectMonth
    }

    public var body: some View {
        switch model {
        case .bars(let columns):
            bars(columns)
        case .hours(let columns, let axis):
            hourBars(columns, axis: axis)
        case .month(let headers, let cells):
            month(headers: headers, cells: cells)
        case .year(let months):
            yearWall(months)
        }
    }

    private func bars(_ columns: [StudyChartColumn]) -> some View {
        let peak = max(columns.map(\.value).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(columns) { column in
                Button {
                    onSelectOffset(column.offset)
                } label: {
                    VStack(spacing: 6) {
                        columnCaption(column.label, emphasized: column.isSelected)
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barFill(column))
                            .frame(height: barHeight(value: column.value, peak: peak))
                        columnCaption(column.axis, emphasized: column.isSelected)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 108)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility(column))
            }
        }
        .padding(.vertical, 4)
    }

    private func hourBars(_ columns: [StudyChartColumn], axis: [StudyAxisLabel]) -> some View {
        let peak = max(columns.map(\.value).max() ?? 0, 1)
        return VStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(columns) { column in
                    columnCaption(column.label, emphasized: false)
                        .minimumScaleFactor(0.4)
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
            .frame(height: 72, alignment: .bottom)
            hourScale(axis, slots: columns.count)
        }
        .padding(.vertical, 4)
    }

    /// The word is centered on its hour column, so the middle of "Morning"
    /// lines up with 6, "Noon" with 12, "Evening" with 18, "Midnight" with 0.
    private func hourScale(_ marks: [StudyAxisLabel], slots: Int) -> some View {
        let titled = Dictionary(uniqueKeysWithValues: marks.map { ($0.slot, $0.title) })
        return HStack(spacing: 1) {
            ForEach(0..<slots, id: \.self) { slot in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
                    .overlay {
                        if let title = titled[slot] {
                            hourTick(title)
                        }
                    }
            }
        }
    }

    private func columnCaption(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .amgiFont(.micro)
            .foregroundStyle(emphasized ? palette.textPrimary : palette.textTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    private func hourTick(_ label: String) -> some View {
        Text(label)
            .amgiFont(.micro)
            .foregroundStyle(palette.textTertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private func barHeight(value: Int, peak: Int) -> CGFloat {
        if value <= 0 { return 2 }
        return max(8, 72 * CGFloat(value) / CGFloat(peak))
    }

    private func barFill(_ column: StudyChartColumn) -> Color {
        if column.isSelected { return palette.accent }
        if column.isFuture { return palette.textTertiary.opacity(0.45) }
        if column.value == 0 { return palette.separator }
        return palette.accent.opacity(column.isToday ? 0.7 : 0.4)
    }

    private func accessibility(_ column: StudyChartColumn) -> String {
        "\(column.label), \(column.value)"
    }

    private func month(headers: [String], cells: [StudyMonthCell]) -> some View {
        let peak = max(cells.map(\.value).max() ?? 0, 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                Text(header)
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(cells) { cell in
                if let offset = cell.offset {
                    Button {
                        onSelectOffset(offset)
                    } label: {
                        monthCell(cell, peak: peak)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(height: 36)
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
            .frame(height: 36)
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

    private func yearWall(_ months: [StudyYearMonth]) -> some View {
        let peak = max(months.flatMap(\.cells).map(\.value).max() ?? 0, 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
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
                    } else {
                        Color.clear.frame(height: 16)
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
            .frame(height: 16)
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
