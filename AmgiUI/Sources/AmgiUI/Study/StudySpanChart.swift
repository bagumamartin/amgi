public import SwiftUI
import AmgiTheme

/// Week bars or a month grid. Tapping a day selects it.
public struct StudySpanChart: View {
    let model: StudyChartModel
    let onSelectOffset: (Int) -> Void

    @Environment(\.palette) private var palette

    public init(model: StudyChartModel, onSelectOffset: @escaping (Int) -> Void) {
        self.model = model
        self.onSelectOffset = onSelectOffset
    }

    public var body: some View {
        switch model {
        case .bars(let columns):
            bars(columns)
        case .month(let headers, let cells):
            month(headers: headers, cells: cells)
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
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barFill(column))
                            .frame(height: barHeight(value: column.value, peak: peak))
                        Text(column.label)
                            .amgiFont(.micro)
                            .foregroundStyle(column.isSelected ? palette.textPrimary : palette.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility(column))
            }
        }
        .frame(height: 108)
        .padding(.vertical, 4)
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
                        monthCell(cell)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(height: 36)
                }
            }
        }
    }

    private func monthCell(_ cell: StudyMonthCell) -> some View {
        VStack(spacing: 2) {
            Text(cell.dayNumber)
                .amgiFont(.caption)
                .foregroundStyle(cell.isSelected ? .white : (cell.isFuture ? palette.textTertiary : palette.textPrimary))
            Circle()
                .fill(cell.value > 0 ? (cell.isSelected ? Color.white.opacity(0.9) : palette.accent) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            cell.isSelected ? palette.accent : (cell.isToday ? palette.accentSoft : Color.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}
