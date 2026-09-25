public import SwiftUI
import AmgiTheme
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
public enum StatsChartStackLayout: Sendable {
    case singleColumn
    case twoColumn
}

public struct StatsChartStack: View {
    private let graphs: GraphsSnapshot
    private let period: StatsPeriod
    private let isCompact: Bool
    private let layout: StatsChartStackLayout

    /// - Parameter isCompact: watch-sized layout. Omits the activity heatmap,
    ///   which needs a year-wide grid to be readable at all.
    /// - Parameter layout: regular-width dashboards use a two-column grid;
    ///   compact and watch surfaces retain the ordered single-column stack.
    public init(
        graphs: GraphsSnapshot,
        period: StatsPeriod,
        isCompact: Bool = false,
        layout: StatsChartStackLayout = .singleColumn
    ) {
        self.graphs = graphs
        self.period = period
        self.isCompact = isCompact
        self.layout = layout
    }

    @ViewBuilder
    public var body: some View {
        switch layout {
        case .singleColumn:
            singleColumn
        case .twoColumn:
            regularDashboard
        }
    }

    private var singleColumn: some View {
        Group {
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

    private var regularDashboard: some View {
        VStack(spacing: AmgiSpacing.lg) {
            PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)

            // The activity and retention summaries need the extra horizontal
            // reading room: the heatmap is a year-scale grid and retention is
            // a three-column comparison table. All quantitative chart cards
            // otherwise share two balanced columns.
            HeatmapChartOptimized(reviews: graphs.reviews)

            chartRow {
                FutureDueChart(futureDue: graphs.futureDue, period: period)
            } chart: {
                ReviewsChart(reviews: graphs.reviews, period: period)
            }

            chartRow {
                CardCountsChart(cardCounts: graphs.cardCounts)
            } chart: {
                IntervalsChart(intervals: graphs.intervals)
            }

            chartRow {
                EaseChart(eases: graphs.eases)
            } chart: {
                HourlyChart(hours: graphs.hours, period: period)
            }

            chartRow {
                ButtonsChart(buttons: graphs.buttons, period: period)
            } chart: {
                AddedChart(added: graphs.added, period: period)
            }

            RetentionChart(trueRetention: graphs.trueRetention)
            RetrievabilityChart(retrievability: graphs.retrievability)
        }
    }

    private func chartRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder chart: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: AmgiSpacing.lg) {
            leading()
                .frame(maxWidth: .infinity)
            chart()
                .frame(maxWidth: .infinity)
        }
    }
}
