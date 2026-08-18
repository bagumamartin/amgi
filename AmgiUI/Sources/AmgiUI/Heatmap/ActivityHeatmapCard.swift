// iOS-only component — Menu/popover/listRowSeparator APIs are unavailable on watchOS.
#if !os(watchOS)
public import SwiftUI
import AmgiTheme

/// GitHub-contribution-style review history grid.
/// Pure rendering — no network I/O. `HeatmapCardData` is pre-computed
/// by the container before being passed in.
/// Placed in the Library list below the deck rows (order: hero → decks → heatmap).
@MainActor
public struct ActivityHeatmapCard: View {
    public let data: HeatmapCardData

    /// Session-only range selection. Default: 180 days (26 weeks).
    @State private var selectedDays: Int = 180
    /// The cell (day offset) currently shown in the popover tooltip.
    @State private var tooltipOffset: Int? = nil

    @Environment(\.palette) private var palette

    public init(data: HeatmapCardData) {
        self.data = data
    }

    // MARK: - Computed grid geometry

    private let weekdayLabelWidth: CGFloat = HeatmapGridMetrics.weekdayLabelWidth

    @State private var gridWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var weeksToShow: Int { selectedDays / 7 + 1 }

    private var weeks: [[Date]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .weekOfYear, value: -(weeksToShow - 1), to: today)!
        let startOfWeek = cal.date(
            from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startDate)
        )!
        var result: [[Date]] = []
        var current = startOfWeek
        while current <= today {
            var week: [Date] = []
            for d in 0..<7 { week.append(cal.date(byAdding: .day, value: d, to: current)!) }
            result.append(week)
            current = cal.date(byAdding: .weekOfYear, value: 1, to: current)!
        }
        return result
    }

    private var monthLabels: [(label: String, weekIndex: Int)] {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        var labels: [(String, Int)] = []
        var lastMonth = -1
        for (idx, week) in weeks.enumerated() {
            let month = Calendar.current.component(.month, from: week[0])
            if month != lastMonth {
                labels.append((fmt.string(from: week[0]), idx))
                lastMonth = month
            }
        }
        return labels
    }

    private func dayOffset(for date: Date) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        let target = Calendar.current.startOfDay(for: date)
        return Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
    }

    // MARK: - Summary stats (filtered to selectedDays)

    private var filteredCounts: [Int: Int] {
        data.counts.filter { $0.key >= -selectedDays && $0.key <= 0 }
    }

    private var totalReviews: Int { filteredCounts.values.reduce(0, +) }

    private var reviewsThisMonth: Int {
        let day = Calendar.current.component(.day, from: Date())
        return (0..<day).reduce(0) { $0 + (filteredCounts[-$1] ?? 0) }
    }

    private var reviewsThisWeek: Int {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let daysFromMonday = (weekday + 5) % 7
        return (0...daysFromMonday).reduce(0) { $0 + (filteredCounts[-$1] ?? 0) }
    }

    private var fittedCellSize: CGFloat {
        HeatmapGridMetrics.cellSize(width: gridWidth, weekCount: weeks.count)
    }

    private var reviewsToday: Int { filteredCounts[0] ?? 0 }

    // MARK: - Body

    public var body: some View {
        AmgiCard(background: .surfaceElevated, shadow: nil) {
            VStack(alignment: .leading, spacing: 12) {
                HeatmapHeaderRow(selectedDays: $selectedDays)
                if data.counts.isEmpty {
                    HeatmapEmptyLabel()
                } else {
                    HeatmapSummaryRow(
                        total: totalReviews,
                        thisMonth: reviewsThisMonth,
                        thisWeek: reviewsThisWeek,
                        today: reviewsToday,
                        spread: horizontalSizeClass != .regular
                    )
                    HeatmapScrollGrid(
                        weeks: weeks,
                        monthLabels: monthLabels,
                        data: data,
                        cellSize: fittedCellSize,
                        cellSpacing: HeatmapGridMetrics.cellSpacing,
                        weekdayLabelWidth: weekdayLabelWidth,
                        containerWidth: gridWidth,
                        dayOffset: dayOffset,
                        tooltipOffset: $tooltipOffset
                    )
                    .frame(height: HeatmapGridMetrics.gridHeight(cellSize: fittedCellSize))
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { gridWidth = $0 }
                    HeatmapLegend(cellSize: fittedCellSize)
                }
            }
        }
    }
}

// MARK: - Grid metrics

private enum HeatmapGridMetrics {
    static let minCell: CGFloat = 11
    static let maxCell: CGFloat = 28
    static let cellSpacing: CGFloat = 2
    static let weekdayLabelWidth: CGFloat = 18
    static let monthHeaderHeight: CGFloat = 14

    static func cellSize(width: CGFloat, weekCount: Int) -> CGFloat {
        guard weekCount > 0, width > weekdayLabelWidth else { return minCell }
        let available = width - weekdayLabelWidth
        let fitted = (available - CGFloat(weekCount - 1) * cellSpacing) / CGFloat(weekCount)
        return min(maxCell, max(minCell, fitted))
    }

    static func contentWidth(weekCount: Int, cellSize: CGFloat) -> CGFloat {
        weekdayLabelWidth
            + CGFloat(weekCount) * cellSize
            + CGFloat(max(weekCount - 1, 0)) * cellSpacing
    }

    static func gridHeight(cellSize: CGFloat) -> CGFloat {
        monthHeaderHeight + 7 * cellSize + 6 * cellSpacing
    }
}

// MARK: - Header (title + range menu)

private struct HeatmapHeaderRow: View {
    @Binding var selectedDays: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text("Activity")
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            Spacer()
            Menu {
                ForEach([90, 180, 365], id: \.self) { days in
                    Button(rangeLabel(days)) { selectedDays = days }
                }
            } label: {
                Label(rangeLabel(selectedDays), systemImage: "line.horizontal.3.decrease.circle")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.accent)
            }
        }
    }

    private func rangeLabel(_ days: Int) -> String {
        switch days {
        case 90:  return "Last 90 days"
        case 180: return "Last 6 months"
        case 365: return "Last 1 year"
        default:  return "\(days) days"
        }
    }
}

// MARK: - Empty state

private struct HeatmapEmptyLabel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Text("No reviews yet")
            .amgiFont(.body)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}

// MARK: - Summary row (above grid)

private struct HeatmapSummaryRow: View {
    let total: Int
    let thisMonth: Int
    let thisWeek: Int
    let today: Int
    /// Compact iPhone: four equal columns. Regular: a tight leading cluster
    /// so stats don't stretch across the iPad/Mac card.
    let spread: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: spread ? 0 : 28) {
            summaryItem(value: total, label: "Total")
            summaryItem(value: thisMonth, label: "Month")
            summaryItem(value: thisWeek, label: "Week")
            summaryItem(value: today, label: "Today")
            if !spread { Spacer(minLength: 0) }
        }
    }

    private func summaryItem(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(palette.textPrimary)
            Text(label)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: spread ? .infinity : nil)
    }
}

// MARK: - Scrollable grid

private struct HeatmapScrollGrid: View {
    let weeks: [[Date]]
    let monthLabels: [(label: String, weekIndex: Int)]
    let data: HeatmapCardData
    let cellSize: CGFloat
    let cellSpacing: CGFloat
    let weekdayLabelWidth: CGFloat
    let containerWidth: CGFloat
    let dayOffset: (Date) -> Int
    @Binding var tooltipOffset: Int?

    private var contentWidth: CGFloat {
        HeatmapGridMetrics.contentWidth(weekCount: weeks.count, cellSize: cellSize)
    }

    private var needsScroll: Bool {
        containerWidth > 0 && contentWidth > containerWidth + 0.5
    }

    var body: some View {
        let grid = VStack(alignment: .leading, spacing: 0) {
            HeatmapMonthHeader(
                weeks: weeks,
                monthLabels: monthLabels,
                cellSize: cellSize,
                cellSpacing: cellSpacing,
                weekdayLabelWidth: weekdayLabelWidth
            )
            HeatmapCellGrid(
                weeks: weeks,
                data: data,
                cellSize: cellSize,
                cellSpacing: cellSpacing,
                weekdayLabelWidth: weekdayLabelWidth,
                dayOffset: dayOffset,
                tooltipOffset: $tooltipOffset
            )
        }

        if needsScroll {
            ScrollView(.horizontal) { grid }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.trailing)
        } else {
            grid
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Month header

private struct HeatmapMonthHeader: View {
    let weeks: [[Date]]
    let monthLabels: [(label: String, weekIndex: Int)]
    let cellSize: CGFloat
    let cellSpacing: CGFloat
    let weekdayLabelWidth: CGFloat

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: weekdayLabelWidth)
            ForEach(0..<weeks.count, id: \.self) { idx in
                if let entry = monthLabels.first(where: { $0.weekIndex == idx }) {
                    Text(entry.label)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize()
                        .frame(width: cellSize + cellSpacing, alignment: .leading)
                } else {
                    Spacer().frame(width: cellSize + cellSpacing)
                }
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Cell grid

private struct HeatmapCellGrid: View {
    let weeks: [[Date]]
    let data: HeatmapCardData
    let cellSize: CGFloat
    let cellSpacing: CGFloat
    let weekdayLabelWidth: CGFloat
    let dayOffset: (Date) -> Int
    @Binding var tooltipOffset: Int?

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            weekdayColumnLabels
            HStack(spacing: cellSpacing) {
                ForEach(0..<weeks.count, id: \.self) { weekIdx in
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<7, id: \.self) { dayIdx in
                            let date = weeks[weekIdx][dayIdx]
                            let offset = dayOffset(date)
                            let count = data.counts[offset] ?? 0
                            let isFuture = date > Date()
                            HeatmapCell(
                                offset: offset,
                                count: count,
                                maxCount: data.maxCount,
                                isFuture: isFuture,
                                date: date,
                                cellSize: cellSize,
                                tooltipOffset: $tooltipOffset
                            )
                        }
                    }
                }
            }
        }
    }

    private var weekdayColumnLabels: some View {
        VStack(spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { dayIndex in
                Text(weekdayLabel(dayIndex))
                    .font(.system(size: 8))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: weekdayLabelWidth, height: cellSize)
            }
        }
    }

    private func weekdayLabel(_ index: Int) -> String {
        switch index {
        case 1: "M"
        case 3: "W"
        case 5: "F"
        default: ""
        }
    }
}

// MARK: - Single cell with popover tooltip

private struct HeatmapCell: View {
    let offset: Int
    let count: Int
    let maxCount: Int
    let isFuture: Bool
    let date: Date
    let cellSize: CGFloat
    @Binding var tooltipOffset: Int?

    @Environment(\.palette) private var palette

    private var isShowingTooltip: Bool { tooltipOffset == offset }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(cellColor)
            .frame(width: cellSize, height: cellSize)
            .onTapGesture {
                tooltipOffset = isShowingTooltip ? nil : offset
            }
            .popover(isPresented: Binding(
                get: { isShowingTooltip },
                set: { if !$0 { tooltipOffset = nil } }
            )) {
                VStack(spacing: 4) {
                    Text(Self.dateFormatter.string(from: date))
                        .amgiFont(.captionBold)
                    Text(count == 0 ? "No reviews" : "\(count) review\(count == 1 ? "" : "s")")
                        .amgiFont(.caption)
                }
                .padding(10)
                .presentationCompactAdaptation(.popover)
            }
    }

    private var cellColor: Color {
        guard !isFuture else { return Color.clear }
        return HeatmapColorRamp.color(count: count, maxCount: maxCount, palette: palette)
    }
}

// MARK: - Legend strip

private struct HeatmapLegend: View {
    let cellSize: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Less").amgiFont(.micro).foregroundStyle(palette.textSecondary)
            ForEach(
                Array(HeatmapColorRamp.legendColors(palette: palette).enumerated()),
                id: \.offset
            ) { _, color in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More").amgiFont(.micro).foregroundStyle(palette.textSecondary)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Empty") {
    ActivityHeatmapCard(data: .empty)
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}

#Preview("Sparse") {
    ActivityHeatmapCard(data: .sparse)
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}

#Preview("Dense") {
    ActivityHeatmapCard(data: .dense)
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}

#Preview("Streak — Muted theme") {
    ActivityHeatmapCard(data: .streak)
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .mutedLight)
}

#Preview("Dense — regular width") {
    ActivityHeatmapCard(data: .dense)
        .padding(16)
        .frame(width: 720)
        .background(Color.gray.opacity(0.1))
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.palette, .vividLight)
}

#Preview("Dense — dark mode") {
    ActivityHeatmapCard(data: .dense)
        .padding(16)
        .background(Color.black)
        .environment(\.palette, .vividDark)
        .preferredColorScheme(.dark)
}
#endif
#endif  // !os(watchOS)
