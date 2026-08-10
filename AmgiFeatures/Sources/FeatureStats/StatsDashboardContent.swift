import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiCharts
public import AnkiKit

/// Pure render-from-data half of the stats dashboard. Owns no dependencies
/// and performs no loading, so every state previews by varying one argument.
struct StatsDashboardContent: View {

    enum State {
        case loading
        case loaded(GraphsSnapshot)
        case failed(String)

        /// Projects the model's three parallel properties into one state.
        /// Order matters: an error wins over stale graphs, and "nothing yet"
        /// reads as loading rather than as a blank screen.
        init(isLoading: Bool, errorMessage: String?, graphs: GraphsSnapshot?) {
            if let errorMessage { self = .failed(errorMessage) }
            else if isLoading { self = .loading }
            else if let graphs { self = .loaded(graphs) }
            else { self = .loading }
        }

        var isLoadingCase: Bool { if case .loading = self { true } else { false } }
        var failureMessage: String? { if case .failed(let m) = self { m } else { nil } }
        var loadedGraphs: GraphsSnapshot? { if case .loaded(let g) = self { g } else { nil } }
    }

    let state: State
    let period: StatsPeriod
    let selectedDeck: DeckInfo?
    /// `model.topLevelDecks`, not `model.decks` — the deck menu renders the
    /// filtered-on-write top-level list (commit `814b51c`), never the full set.
    let topLevelDecks: [DeckInfo]
    let onSelectDeck: (DeckInfo?) -> Void
    let onSelectPeriod: (StatsPeriod) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AmgiSpacing.lg) {
                switch state {
                case .loading:
                    ProgressView("Loading statistics...").padding(.top, 40)
                case .failed(let message):
                    ContentUnavailableView(
                        "Failed to Load Stats",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .loaded(let graphs):
                    filters
                    charts(graphs)
                }
            }
            .padding(AmgiSpacing.lg)
        }
    }

    // MARK: - Filters

    private var filters: some View {
        HStack(spacing: AmgiSpacing.md) {
            deckMenu
            periodMenu
            Spacer()
        }
    }

    private var deckMenu: some View {
        Menu {
            Button { onSelectDeck(nil) } label: {
                if selectedDeck == nil { Label("Whole Collection", systemImage: "checkmark") }
                else { Text("Whole Collection") }
            }
            Divider()
            ForEach(topLevelDecks) { deck in
                Button { onSelectDeck(deck) } label: {
                    if selectedDeck?.id == deck.id { Label(deck.name, systemImage: "checkmark") }
                    else { Text(deck.name) }
                }
            }
        } label: {
            filterCapsule(
                icon: "rectangle.stack",
                label: selectedDeck?.name ?? "Collection"
            )
        }
    }

    private var periodMenu: some View {
        Menu {
            ForEach(StatsPeriod.allCases, id: \.self) { p in
                Button { onSelectPeriod(p) } label: {
                    if period == p { Label(p.rawValue, systemImage: "checkmark") }
                    else { Text(p.rawValue) }
                }
            }
        } label: {
            filterCapsule(
                icon: "calendar",
                label: period.shortLabel
            )
        }
    }

    private func filterCapsule(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .amgiFont(.caption)
            Text(label)
                .fontWeight(.medium)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
        }
        .amgiFont(.body)
        .amgiCapsuleControl()
    }

    // MARK: - Charts

    @ViewBuilder
    private func charts(_ graphs: GraphsSnapshot) -> some View {
        PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)
        FutureDueChart(futureDue: graphs.futureDue, period: period)
        HeatmapChartOptimized(reviews: graphs.reviews)
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

// MARK: - Previews

#if DEBUG
#Preview("Loaded") {
    StatsDashboardContent(
        state: .loaded(.sample), period: .month, selectedDeck: nil,
        topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in }
    )
}

#Preview("Loading") {
    StatsDashboardContent(
        state: .loading, period: .month, selectedDeck: nil,
        topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in }
    )
}

#Preview("Failed") {
    StatsDashboardContent(
        state: .failed("The collection is locked."), period: .month,
        selectedDeck: nil, topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in }
    )
}
#endif
