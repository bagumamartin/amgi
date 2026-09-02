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
    /// One state, not three parallel flags. `isLoading` / `errorMessage` /
    /// `graphs` allowed eight combinations for three renderable states, and
    /// the view had to disambiguate them at the call site.
    var state: StatsDashboardContent.State = .loading
    /// True while a *re*-load runs with graphs already on screen. The old
    /// behaviour — keep the stale graphs, show nothing — was indistinguishable
    /// from having ignored the tap.
    private(set) var isRefreshing = false
    var decks: [DeckInfo] = [] {
        didSet { topLevelDecks = decks.filter { !$0.name.contains("::") } }
    }

    /// Stored so the deck menu doesn't re-filter on every `body` pass.
    private(set) var topLevelDecks: [DeckInfo] = []

    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient

    func loadDecks() async {
        decks = (try? await deckClient.fetchAll()) ?? []
    }

    func loadStats(search: String, days: Int) async {
        // A refresh keeps the previous graphs on screen; only a first load
        // shows the spinner. Preserves the old `isLoading = graphs == nil`.
        if case .loaded = state { isRefreshing = true } else { state = .loading }
        defer { isRefreshing = false }
        do {
            let graphs = try await statsClient.fetchGraphs(search, days)
            // The caller drives this from `.task(id:)`, which cancels the
            // previous load when the period or deck changes. Without this
            // check a slow "All Time" fetch could land after a fast "Month"
            // one and leave the user looking at the wrong period's data under
            // the right period's chip.
            guard !Task.isCancelled else { return }
            state = .loaded(graphs)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // An error wins over stale graphs, as the old projection did.
            state = .failed(error.localizedDescription)
        }
    }
}
