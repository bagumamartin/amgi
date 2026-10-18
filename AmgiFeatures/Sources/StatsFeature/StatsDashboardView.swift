package import SwiftUI
import AmgiAppShared
import AmgiUI
import AmgiCharts
package import AnkiKit
import AnkiClients
import AssistantFeature
import Dependencies

package struct StatsDashboardView: View {
    /// Bumped by the host after sync / import / review so the dashboard
    /// reloads. Keyed into `.task` rather than applied as an `.id` — an `.id`
    /// change discards the whole subtree's identity, throwing away the
    /// selected deck, the period, and the scroll position to achieve a reload
    /// the task already does.
    private let refreshID: UUID?
    private let locksDeckScope: Bool

    @State private var model = StatsDashboardModel()
    @State private var period: StatsPeriod = .month
    @State private var selectedDeck: DeckInfo?
    /// Publishes to the assistant only while showing — not from a tab in
    /// the background.
    @State private var isOnScreen = false

    package init(refreshID: UUID? = nil, deck: DeckInfo? = nil, locksDeckScope: Bool = false) {
        self.refreshID = refreshID
        self.locksDeckScope = locksDeckScope
        _selectedDeck = State(initialValue: deck)
    }

    package var body: some View {
        StatsDashboardContent(
            state: model.state,
            period: period,
            selectedDeck: selectedDeck,
            topLevelDecks: model.topLevelDecks,
            onSelectDeck: { selectedDeck = $0 },
            onSelectPeriod: { period = $0 },
            isRefreshing: model.isRefreshing,
            allowsDeckSelection: !locksDeckScope,
            // A period at least as long as the lookback already carries more
            // history than the heatmap fetch would.
            heatmapReviews: period.days >= StatsDashboardModel.heatmapLookbackDays
                ? nil : model.heatmapReviews
        )
        .scrollContentBackground(.hidden)
        .amgiScreenCanvas()
        .navigationTitle("Statistics")
        .preference(key: AssistantScreenContextKey.self, value: isOnScreen ? [assistantContext] : [])
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SyncToolbarButton()
            }
        }
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
        // The heatmap's history ignores the period, so it gets its own key:
        // switching period never refetches it, and it loads beside the
        // period's charts instead of after them.
        .task(id: HeatmapQuery(refreshID: refreshID, deckName: selectedDeck?.name)) {
            await model.loadHeatmapReviews(search: search)
        }
        .refreshable {
            async let stats: Void = reloadStats()
            async let heatmap: Void = model.loadHeatmapReviews(search: search)
            _ = await (stats, heatmap)
        }
    }
}

private struct HeatmapQuery: Equatable {
    let refreshID: UUID?
    let deckName: String?
}

/// Everything the stats fetch depends on, as one `.task(id:)` key.
private struct StatsQuery: Equatable {
    let refreshID: UUID?
    let periodDays: Int
    let deckName: String?
}

private extension StatsDashboardView {
    /// The dashboard as filtered, with the figures it is showing.
    var assistantContext: AssistantContext {
        let summary: String = if case .loaded(let snapshot) = model.state {
            StatsAssistantSummary.text(snapshot, period: period, deck: selectedDeck?.name)
        } else { "" }
        return .stats(
            period: period.rawValue, days: period.days, deckID: selectedDeck?.id.rawValue,
            deckName: selectedDeck?.name, summary: summary
        )
    }

    var query: StatsQuery {
        StatsQuery(
            refreshID: refreshID,
            periodDays: period.days,
            deckName: selectedDeck?.name
        )
    }

    /// Bridge the view's filter state into the model's stats load.
    var search: String {
        selectedDeck.map { DeckSearch.term($0.name) } ?? ""
    }

    func reloadStats() async {
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
