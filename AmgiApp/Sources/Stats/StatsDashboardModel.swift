import AnkiClients
import AnkiKit
import Dependencies
import Foundation

/// Statistics-graph I/O for the stats dashboard. Owns the stats + deck
/// clients and the loaded graphs/deck list plus load state, so the view
/// carries no `@Dependency`; the period and selected-deck filter state stays
/// on the view and is passed into `loadStats`.
@Observable
@MainActor
final class StatsDashboardModel {
    var graphs: GraphsSnapshot?
    var heatmapReviews: ReviewCountsAndTimes?
    var isLoading = true
    var errorMessage: String?
    var decks: [DeckInfo] = []

    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient

    /// Lookback used exclusively by the heatmap so its own range picker isn't
    /// clamped by the dashboard's period filter.
    private static let heatmapLookbackDays = 730

    func loadDecks() async {
        decks = (try? await deckClient.fetchAll()) ?? []
    }

    func loadStats(search: String, days: Int) async {
        isLoading = graphs == nil
        let client = statsClient
        do {
            let mainGraphs = try await client.fetchGraphs(search, days)
            graphs = mainGraphs
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }

        // Heatmap data is best-effort: a failure here keeps the period-scoped
        // dashboard charts, and the view falls back to `graphs.reviews`.
        heatmapReviews = (try? await client.fetchGraphs(search, Self.heatmapLookbackDays))?.reviews
        isLoading = false
    }
}
