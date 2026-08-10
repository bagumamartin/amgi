public import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiCharts
import AnkiKit
import AnkiClients
import Dependencies

public struct StatsDashboardView: View {
    @Environment(\.palette) private var palette

    @State private var model = StatsDashboardModel()
    @State private var period: StatsPeriod = .month
    @State private var selectedDeck: DeckInfo?

    public init() {}

    public var body: some View {
        StatsDashboardContent(
            state: .init(
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                graphs: model.graphs
            ),
            period: period,
            selectedDeck: selectedDeck,
            topLevelDecks: model.topLevelDecks,
            onSelectDeck: { selectedDeck = $0 },
            onSelectPeriod: { period = $0 }
        )
        .scrollContentBackground(.hidden)
        .background(palette.surface)
        .navigationTitle("Statistics")
        .task {
            await model.loadDecks()
            await reloadStats()
        }
        .onAppear {
            Task { await reloadStats() }
        }
        .refreshable { await reloadStats() }
        .onChange(of: selectedDeck) {
            Task { await reloadStats() }
        }
        .onChange(of: period) {
            Task { await reloadStats() }
        }
    }
}

private extension StatsDashboardView {
    /// Bridge the view's filter state into the model's stats load.
    func reloadStats() async {
        let search = selectedDeck.map { "deck:\"\($0.name)\"" } ?? ""
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
