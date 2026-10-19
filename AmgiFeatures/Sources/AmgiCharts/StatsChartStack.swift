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
    private let pairsCharts: Bool
    private let pairSpacing: CGFloat
    private let heatmapReviews: ReviewCountsAndTimes?

    /// - Parameter isCompact: watch-sized layout. Omits the activity heatmap,
    ///   which needs a year-wide grid to be readable at all.
    /// - Parameter heatmapReviews: a lookback wider than `period`, so the
    ///   heatmap can show days outside the period (muted) instead of blanks.
    ///   Falls back to `graphs.reviews`, which only covers the period.
    /// - Parameter pairsCharts: iPad landscape and Mac. The summary and the
    ///   heatmap stay full width; every other chart sits beside its partner.
    public init(
        graphs: GraphsSnapshot,
        period: StatsPeriod,
        isCompact: Bool = false,
        pairsCharts: Bool = false,
        pairSpacing: CGFloat = 16,
        heatmapReviews: ReviewCountsAndTimes? = nil
    ) {
        self.graphs = graphs
        self.period = period
        self.isCompact = isCompact
        self.pairsCharts = pairsCharts && !isCompact
        self.pairSpacing = pairSpacing
        self.heatmapReviews = heatmapReviews
    }

    public var body: some View {
        if pairsCharts {
            pairedBody
        } else {
            stackedBody
        }
    }

    /// Same charts as `stackedBody`, in pairs that belong together: what is
    /// due beside what was reviewed, the card mix beside its intervals, and
    /// so on.
    @ViewBuilder
    private var pairedBody: some View {
        PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)
        HeatmapChartOptimized(
            reviews: heatmapReviews ?? graphs.reviews,
            attentionDays: period.days
        )
        StatsChartPair(spacing: pairSpacing) {
            FutureDueChart(futureDue: graphs.futureDue, period: period)
        } trailing: {
            ReviewsChart(reviews: graphs.reviews, period: period)
        }
        StatsChartPair(spacing: pairSpacing) {
            CardCountsChart(cardCounts: graphs.cardCounts)
        } trailing: {
            IntervalsChart(intervals: graphs.intervals)
        }
        StatsChartPair(spacing: pairSpacing) {
            ButtonsChart(buttons: graphs.buttons, period: period)
        } trailing: {
            HourlyChart(hours: graphs.hours, period: period)
        }
        StatsChartPair(spacing: pairSpacing) {
            AddedChart(added: graphs.added, period: period)
        } trailing: {
            RetentionChart(trueRetention: graphs.trueRetention)
        }
        StatsChartPair(spacing: pairSpacing) {
            RetrievabilityChart(retrievability: graphs.retrievability)
        } trailing: {
            EaseChart(eases: graphs.eases)
        }
    }

    @ViewBuilder
    private var stackedBody: some View {
        PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)
        FutureDueChart(futureDue: graphs.futureDue, period: period)
        if !isCompact {
            HeatmapChartOptimized(
                reviews: heatmapReviews ?? graphs.reviews,
                attentionDays: period.days
            )
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

/// Two charts side by side at equal widths, top aligned.
private struct StatsChartPair<Leading: View, Trailing: View>: View {
    let spacing: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            leading
                .frame(maxWidth: .infinity)
            trailing
                .frame(maxWidth: .infinity)
        }
    }
}
