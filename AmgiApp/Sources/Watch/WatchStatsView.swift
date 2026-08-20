import AmgiCharts
import AnkiClients
import AnkiKit
import Dependencies
import SwiftUI

struct WatchStatsView: View {
    @Dependency(\.statsClient) var statsClient
    @Dependency(\.deckClient) var deckClient
    /// One axis instead of an `isLoading` / `graphs?` / `errorMessage?` trio,
    /// which had eight combinations for three renderable states — including
    /// "not loading, no graphs, no error", which rendered nothing at all.
    enum LoadState {
        case loading
        case loaded(GraphsSnapshot)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var period: StatsPeriod = .month
    @State private var decks: [DeckInfo] = []
    @State private var selectedDeck: DeckInfo?
    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading...")
            case .failed(let error):
                Text(error)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding()
            case .loaded(let graphs):
                List {
                    Section {
                        deckPicker
                        periodPicker
                    }
                    Group {
                        PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)
                        FutureDueChart(futureDue: graphs.futureDue, period: period)
                        ReviewsChart(reviews: graphs.reviews, period: period)
                        CardCountsChart(cardCounts: graphs.cardCounts)
                        IntervalsChart(intervals: graphs.intervals)
                        EaseChart(eases: graphs.eases)
                        HourlyChart(hours: graphs.hours, period: period)
                        ButtonsChart(buttons: graphs.buttons, period: period)
                        AddedChart(added: graphs.added, period: period)
                        RetentionChart(trueRetention: graphs.trueRetention)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Stats")
        .task { await loadDecks() }
        // Keyed on the two inputs the query is built from, so changing either
        // cancels the in-flight fetch instead of racing it.
        .task(id: StatsQuery(deck: selectedDeck, period: period)) {
            await loadStats()
        }
    }

    /// The inputs `loadStats` reads, as one `.task(id:)` key.
    private struct StatsQuery: Equatable {
        let deck: DeckInfo?
        let period: StatsPeriod
    }
    private var deckPicker: some View {
        Picker(selection: $selectedDeck) {
            Text("Collection").tag(nil as DeckInfo?)
            ForEach(decks.filter({ !$0.name.contains("::") })) { deck in
                Text(deck.name).tag(deck as DeckInfo?)
            }
        } label: {
            Text("Deck")
        }
    }
    private var periodPicker: some View {
        Picker(selection: $period) {
            ForEach(StatsPeriod.allCases, id: \.self) { p in
                Text(p.rawValue).tag(p)
            }
        } label: {
            Text("Period")
        }
    }
    private func loadDecks() async {
        decks = (try? await deckClient.fetchAll()) ?? []
    }
    private func loadStats() async {
        do {
            let search = selectedDeck.map { DeckSearch.term($0.name) } ?? ""
            let graphs = try await statsClient.fetchGraphs(search, period.days)
            guard !Task.isCancelled else { return }
            state = .loaded(graphs)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
