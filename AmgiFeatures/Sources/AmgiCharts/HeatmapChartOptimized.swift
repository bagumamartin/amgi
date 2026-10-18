public import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
public import AnkiKit

/// Review heatmap.
/// - By default it shows as many weeks as fit the available width — more on
///   a wide iPad or Mac window — and follows window resizing column by column.
/// - It never shows less than the selected period; when the period is wider
///   than the space, the grid scrolls instead.
/// - A range picked from the menu overrides the fit and is remembered.
public struct HeatmapChartOptimized: View {
    let reviews: ReviewCountsAndTimes
    /// Number of most-recent days rendered with the normal intensity ramp;
    /// older cells are muted to mark them as outside the selected period.
    /// `nil` disables the distinction.
    var attentionDays: Int? = nil

    public init(
        reviews: ReviewCountsAndTimes,
        attentionDays: Int? = nil,
        compactHeight: CGFloat? = nil
    ) {
        self.reviews = reviews
        self.attentionDays = attentionDays
        self.compactHeight = compactHeight
    }

    @Environment(\.palette) private var palette
    /// `0` fits the grid to the available width (the default); otherwise the
    /// range in days the user picked from the menu, kept across launches.
    @AppStorage("statsHeatmapRangeDays") private var pickedRangeDays = 0
    /// Week-columns that fit the measured width. Integer, so a live window
    /// resize only re-renders when a whole column appears or disappears.
    @State private var fittingWeeks: Int?
    /// Day offset → review total over the whole history handed in. Built once
    /// per `reviews`, so resizing and range changes are synchronous filters
    /// over it rather than a reload.
    @State private var allCounts: [Int: Int] = [:]
    /// Colour scale. Taken over everything loaded, not the visible window,
    /// so resizing the window never recolours the cells already on screen.
    @State private var maxCount: Int = 1
    /// Rebuilds the grid only when the range, counts, or calendar day change.
    @State private var gridCache = HeatmapGridCache()

    /// The longest range offered, and the depth of the history the stats
    /// screen loads for the heatmap.
    private static let maxRangeDays = 730
    /// Used until the width is first measured, and on a narrow screen when
    /// six months can't fit anyway.
    private static let fallbackRangeDays = 180

    var compactHeight: CGFloat? = nil

    private var isCompact: Bool {
        compactHeight != nil
    }

    private var cellSpacing: CGFloat {
        isCompact ? 1.25 : 2
    }

    private var weekdayLabelWidth: CGFloat {
        isCompact ? 16 : 22
    }

    private var cellSize: CGFloat {
        guard let compactHeight else { return 12 }
        let reservedHeight: CGFloat = 92
        let availableGridHeight = max(56, compactHeight - reservedHeight)
        let computed = (availableGridHeight - (cellSpacing * 6)) / 7
        return min(12, max(7, computed))
    }

    private var contentWidth: CGFloat {
        weekdayLabelWidth
            + CGFloat(grid.weeks.count) * cellSize
            + CGFloat(max(grid.weeks.count - 1, 0)) * cellSpacing
    }

    private var gridHeight: CGFloat {
        14 + 7 * cellSize + 6 * cellSpacing
    }

    // MARK: - Derived Computed Properties (sync, over snapshot)

    private var currentStreak: Int {
        // Shared with the Library hero card via AnkiKit.DayStreak. This used
        // to be a third, subtly different implementation, so the two screens
        // could disagree about the same user's streak. Windowed to the range
        // on screen.
        DayStreak.count(totals: visibleData, window: shownDays)
    }

    /// Reviews on the days the grid actually shows — what "Total" sums.
    private var visibleData: [Int: Int] {
        let oldest = -shownDays
        return allCounts.filter { $0.key > oldest }
    }

    private var totalReviews: Int {
        visibleData.values.reduce(0, +)
    }

    private var reviewsThisWeek: Int {
        let today = Calendar.current.startOfDay(for: Date())
        let weekday = Calendar.current.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        return (0...daysFromMonday).reduce(0) { $0 + (visibleData[-$1] ?? 0) }
    }

    private var reviewsThisMonth: Int {
        let day = Calendar.current.component(.day, from: Date())
        return (0..<day).reduce(0) { $0 + (visibleData[-$1] ?? 0) }
    }

    // MARK: - Grid Data

    private var grid: HeatmapGrid {
        gridCache.grid(weekCount: weeksToShow, counts: allCounts)
    }

    private var isFittingWidth: Bool { pickedRangeDays == 0 }

    /// Columns to draw. Fit mode takes what the width allows but never less
    /// than the selected period; a picked range is drawn as picked.
    private var weeksToShow: Int {
        let cap = Self.weeks(covering: Self.maxRangeDays)
        guard isFittingWidth else {
            return min(Self.weeks(covering: pickedRangeDays), cap)
        }
        let fit = fittingWeeks ?? Self.weeks(covering: Self.fallbackRangeDays)
        let period = attentionDays.map { Self.weeks(covering: min($0, Self.maxRangeDays)) } ?? 0
        return min(max(fit, period, 1), cap)
    }

    /// Days from the grid's first cell through today.
    private var shownDays: Int {
        max(1, 1 - (grid.weeks.first?.days.first?.offset ?? 0))
    }

    /// Columns needed for `days` days ending today; the last column is the
    /// current, partial week.
    static func weeks(covering days: Int) -> Int {
        days / 7 + 1
    }

    func weeksThatFit(width: CGFloat) -> Int {
        let column = cellSize + cellSpacing
        return max(1, Int(((width - weekdayLabelWidth + cellSpacing) / column).rounded(.down)))
    }

    // MARK: - Body

    public var body: some View {
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            heatmapContent()
        }
        // Keyed on the data: a deck change, or the wider-than-period history
        // arriving after the first render, has to rebuild the grid. A bare
        // `.task` ran once and kept showing whatever it was first handed.
        .task(id: reviews) { loadCounts() }
    }
}

private extension HeatmapChartOptimized {
    func heatmapContent() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reviews")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Date range picker (when not compact). `Menu(content:label:)` is
                // unavailable on watchOS; AmgiCharts compiles as one module for
                // every platform in Package.swift, and the watch app never
                // references this view, so the picker is iOS/macOS-only.
                #if !os(watchOS)
                if !isCompact {
                    Menu {
                        rangeOption(L10n.text("Fit to Window"), days: 0)
                        Divider()
                        ForEach([30, 90, 180, 365, 730], id: \.self) { days in
                            rangeOption(dateRangeLabel(days), days: days)
                        }
                    } label: {
                        Label(rangeMenuTitle, systemImage: "line.horizontal.3.decrease.circle")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.accent)
                            .contentTransition(.numericText())
                    }
                    .fixedSize()
                }
                #endif

                if currentStreak > 0 {
                    Label(L10n.format("%lld-day streak", [currentStreak]), systemImage: "flame.fill")
                        .amgiFont(.captionBold)
                        .foregroundStyle(palette.warning)
                }
            }

            if allCounts.isEmpty {
                Text("No reviews yet")
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: isCompact ? 72 : 100)
            } else {
                if !isCompact {
                    HStack(spacing: 16) {
                        summaryItem(value: "\(totalReviews)", label: L10n.text("Total"))
                        summaryItem(value: "\(reviewsThisMonth)", label: L10n.text("This month"))
                        summaryItem(value: "\(reviewsThisWeek)", label: L10n.text("This week"))
                        summaryItem(value: "\(visibleData[0] ?? 0)", label: L10n.text("Today"))
                    }
                }

                // Scroll only when the fixed-size grid is wider than the container;
                // otherwise left-align so short ranges don't sit off to the right.
                GeometryReader { geo in
                    let grid = VStack(alignment: .leading, spacing: 0) {
                        monthHeaderView()
                        gridView()
                    }
                    .id("heatmapContent")

                    if contentWidth > geo.size.width + 0.5 {
                        ScrollView(.horizontal, showsIndicators: !isCompact) {
                            grid
                        }
                        .defaultScrollAnchor(.trailing)
                    } else {
                        // Fitting the width: pin today to the trailing edge,
                        // in line with the legend, so a resize adds or drops
                        // the oldest column and the newest never moves. A
                        // short picked range left-aligns as before.
                        grid
                            .frame(maxWidth: .infinity, alignment: isFittingWidth ? .trailing : .leading)
                    }
                }
                .frame(height: gridHeight)

                legendView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card's content width, which comes from the parent and not from
        // the grid, so drawing more columns can't feed back into the measure.
        .onGeometryChange(for: Int.self) { proxy in
            weeksThatFit(width: proxy.size.width)
        } action: { weeks in
            fittingWeeks = weeks
        }
    }

    #if !os(watchOS)
    func rangeOption(_ title: String, days: Int) -> some View {
        Button {
            pickedRangeDays = days
        } label: {
            if pickedRangeDays == days { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
    #endif

    /// The picked range, or in fit mode the span actually on screen — so the
    /// button says what widening the window just did.
    var rangeMenuTitle: String {
        guard isFittingWidth else { return dateRangeLabel(pickedRangeDays) }
        let months = Int((Double(shownDays) / 30.44).rounded())
        if months < 2 { return L10n.format("%lld days", [shownDays]) }
        if months >= 24 { return dateRangeLabel(730) }
        if months == 12 { return dateRangeLabel(365) }
        return L10n.format("Last %lld months", [months])
    }

    // MARK: - View Components
}

private extension HeatmapChartOptimized {
    func monthHeaderView() -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: weekdayLabelWidth)
            let weeks = grid.weeks
            ForEach(weeks.indices, id: \.self) { index in
                // A label needs about two columns. The oldest column usually
                // holds the tail of a month whose label would run into the
                // next month's ("DecJan"), and it shifts with every resize.
                let crowded = weeks.indices.contains(index + 1) && weeks[index + 1].monthLabel != nil
                if let label = weeks[index].monthLabel, !crowded {
                    Text(label)
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

    func gridView() -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: cellSpacing) {
                ForEach(0..<7, id: \.self) { day in
                    Text(weekdayLabel(day))
                        .font(.system(size: 8))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: weekdayLabelWidth, height: cellSize)
                }
            }

            HStack(spacing: cellSpacing) {
                ForEach(grid.weeks) { week in
                    VStack(spacing: cellSpacing) {
                        ForEach(week.days) { day in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    cellColor(
                                        count: day.count,
                                        isFuture: day.isFuture,
                                        isAttention: isInPeriod(day.offset)
                                    )
                                )
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    /// `attentionDays` covers today plus the `n - 1` days before it — the same
    /// window the period's own graphs fetch — so offset `-n` is already out.
    func isInPeriod(_ offset: Int) -> Bool {
        attentionDays.map { offset > -$0 } ?? true
    }

    func cellColor(count: Int, isFuture: Bool, isAttention: Bool) -> Color {
        if isFuture { return .clear }
        if isAttention {
            return HeatmapColorRamp.color(count: count, maxCount: maxCount, palette: palette)
        }
        // Out-of-period: same intensity ramp, in greyscale instead of accent.
        return HeatmapColorRamp.color(
            count: count,
            maxCount: maxCount,
            base: palette.textPrimary,
            empty: palette.separator
        )
    }

    func legendView() -> some View {
        HStack(spacing: isCompact ? 3 : 4) {
            Text("Less").amgiFont(.micro).foregroundStyle(palette.textSecondary)
            ForEach(Array(HeatmapColorRamp.legendColors(palette: palette).enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More").amgiFont(.micro).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Helpers

    func summaryItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .amgiFont(.bodyEmphasis)
                .monospacedDigit()
            Text(label)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    func weekdayLabel(_ index: Int) -> String {
        // Locale-aware initials for Monday, Wednesday and Friday, wherever
        // those land. Rows start at the calendar's own first weekday
        // (`HeatmapGrid` builds weeks from `Calendar.current`), so fixed rows
        // 1/3/5 read Tue/Thu/Sat on a Monday-first calendar.
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let sundayFirstIndex = (calendar.firstWeekday - 1 + index) % 7
        // Sunday-first: 1 = Monday, 3 = Wednesday, 5 = Friday.
        guard [1, 3, 5].contains(sundayFirstIndex),
              symbols.indices.contains(sundayFirstIndex) else { return "" }
        return symbols[sundayFirstIndex]
    }

    func dateRangeLabel(_ days: Int) -> String {
        switch days {
        case 30: return L10n.text("Last 30 days")
        case 90: return L10n.text("Last 90 days")
        case 180: return L10n.text("Last 6 months")
        case 365: return L10n.text("Last 1 year")
        case 730: return L10n.text("Last 2 years")
        default: return L10n.format("%lld days", [days])
        }
    }

    // MARK: - Loading

    /// Flattens the per-state counts once per `reviews`. Everything else —
    /// width, range, period — filters this synchronously, so nothing waits on
    /// a reload and resizing never shows half-filled columns.
    func loadCounts() {
        var counts: [Int: Int] = [:]
        var peak = 1
        for (offset, rev) in reviews.count where offset <= 0 && offset > -Self.maxRangeDays {
            let total = Int(rev.learn + rev.relearn + rev.young + rev.mature + rev.filtered)
            guard total > 0 else { continue }
            counts[Int(offset)] = total
            peak = Swift.max(peak, total)
        }
        allCounts = counts
        maxCount = peak
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HeatmapChartOptimized(reviews: .sampleYear)
        .padding()
}
#endif
