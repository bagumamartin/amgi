public import SwiftUI
public import AnkiKit

/// The ordered set of statistics charts, shared by the iOS dashboard and the
/// watch's stats screen.
///
/// Both used to spell the list out themselves and had already drifted — the
/// watch was missing the heatmap and the retrievability chart, because the
/// iOS scheme doesn't build `AmgiWatchApp` and nothing flags a chart that
/// never reached it. One list means adding a chart reaches both surfaces, or
/// neither.
///
/// Lives in `AmgiCharts` because that is the only module both link, and it is
/// watchOS-clean in its entirety.
public struct StatsChartStack: View {
    private let graphs: GraphsSnapshot
    private let period: StatsPeriod
    private let isCompact: Bool

    /// - Parameter isCompact: watch-sized layout. Omits the activity heatmap,
    ///   which needs a year-wide grid to be readable at all.
    public init(graphs: GraphsSnapshot, period: StatsPeriod, isCompact: Bool = false) {
        self.graphs = graphs
        self.period = period
        self.isCompact = isCompact
    }

    public var body: some View {
        PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)
        FutureDueChart(futureDue: graphs.futureDue, period: period)
        if !isCompact {
            HeatmapChartOptimized(reviews: graphs.reviews)
        }
        ReviewsChart(reviews: graphs.reviews, period: period)
        CardCountsChart(cardCounts: graphs.cardCounts)
        IntervalsChart(intervals: graphs.intervals)
        EaseChart(eases: graphs.eases)
        HourlyChart(hours: graphs.hours, period: period)
        ButtonsChart(buttons: graphs.buttons, period: period)
        AddedChart(added: graphs.added, period: period)
        RetentionChart(trueRetention: graphs.trueRetention)
        RetrievabilityChart(retrievability: graphs.retrievability)
    }
}
