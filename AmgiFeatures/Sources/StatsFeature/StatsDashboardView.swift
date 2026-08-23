public import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiCharts
import AnkiKit
import AnkiClients
import Dependencies

public struct StatsDashboardView: View {
    @Environment(\.palette) private var palette

    /// Bumped by the host after sync / import / review so the dashboard
    /// reloads. Keyed into `.task` rather than applied as an `.id` — an `.id`
    /// change discards the whole subtree's identity, throwing away the
    /// selected deck, the period, and the scroll position to achieve a reload
    /// the task already does.
    private let refreshID: UUID?

    @State private var model = StatsDashboardModel()
    @State private var period: StatsPeriod = .month
    @State private var selectedDeck: DeckInfo?

    public init(refreshID: UUID? = nil) {
        self.refreshID = refreshID
    }

    public var body: some View {
        StatsDashboardContent(
            state: model.state,
            period: period,
            selectedDeck: selectedDeck,
            topLevelDecks: model.topLevelDecks,
            onSelectDeck: { selectedDeck = $0 },
            onSelectPeriod: { period = $0 },
            isRefreshing: model.isRefreshing
        )
        .scrollContentBackground(.hidden)
        .background(palette.surface)
        .navigationTitle("Statistics")
        // `.task` already re-runs whenever the view re-enters the hierarchy —
        // an `.onAppear` reload alongside it fetched every graph twice per
        // visit, which on "All Time" means scanning the whole revlog twice.
        // Deck list only depends on the collection, not on the filters.
        .task(id: refreshID) { await model.loadDecks() }
        // One keyed task for the stats, not three unstructured `Task {}`s:
        // SwiftUI cancels the previous load when the key changes, so a slow
        // fetch can no longer land after a newer one and show the wrong
        // period's data.
        .task(id: query) { await reloadStats() }
        .refreshable { await reloadStats() }
    }
}

/// Everything the stats fetch depends on, as one `.task(id:)` key.
private struct StatsQuery: Equatable {
    let refreshID: UUID?
    let periodDays: Int
    let deckName: String?
}

private extension StatsDashboardView {
    var query: StatsQuery {
        StatsQuery(
            refreshID: refreshID,
            periodDays: period.days,
            deckName: selectedDeck?.name
        )
    }

    /// Bridge the view's filter state into the model's stats load.
    func reloadStats() async {
        let search = selectedDeck.map { DeckSearch.term($0.name) } ?? ""
        await model.loadStats(search: search, days: period.days)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    // `prepareDependencies` sets the defaults the view reads via @Dependency in
    // its body; `.previewValue` returns a fully-populated snapshot so every
    // chart renders.
    let _ = prepareDependencies {
        $0.statsClient = .previewValue
        $0.deckClient = .previewValue
    }
    NavigationStack {
        StatsDashboardView()
    }
}
#endif
