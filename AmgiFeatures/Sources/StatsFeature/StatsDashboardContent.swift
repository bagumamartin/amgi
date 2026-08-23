import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiCharts
import AnkiKit

/// Pure render-from-data half of the stats dashboard. Owns no dependencies
/// and performs no loading, so every state previews by varying one argument.
struct StatsDashboardContent: View {

    enum State {
        case loading
        case loaded(GraphsSnapshot)
        case failed(String)

        // The projecting init and its three case-accessors are gone — the
        // model stores this enum directly, so there is nothing to project
        // from and nothing was reading the accessors.
    }

    let state: State
    let period: StatsPeriod
    let selectedDeck: DeckInfo?
    /// `model.topLevelDecks`, not `model.decks` — the deck menu renders the
    /// filtered-on-write top-level list (commit `814b51c`), never the full set.
    let topLevelDecks: [DeckInfo]
    let onSelectDeck: (DeckInfo?) -> Void
    let onSelectPeriod: (StatsPeriod) -> Void
    /// A period/deck change keeps the previous graphs on screen rather than
    /// blanking to a spinner — but silently, the screen was indistinguishable
    /// from one that had ignored the tap. This marks the wait.
    let isRefreshing: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AmgiSpacing.lg) {
                // Outside the switch: the filters used to render only in
                // `.loaded`, so during the first load — the slowest case, and
                // the one where the user most wants a cheaper period — there
                // was nothing on screen to change.
                filters

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
                    charts(graphs)
                        .opacity(isRefreshing ? 0.4 : 1)
                        .overlay(alignment: .top) {
                            if isRefreshing { ProgressView().padding(.top, 40) }
                        }
                        .animation(AmgiMotion.standard, value: isRefreshing)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        StatsChartStack(graphs: graphs, period: period)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Loaded") {
    StatsDashboardContent(
        state: .loaded(.sample), period: .month, selectedDeck: nil,
        topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: false
    )
}

#Preview("Refreshing") {
    StatsDashboardContent(
        state: .loaded(.sample), period: .year, selectedDeck: nil,
        topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: true
    )
}

#Preview("Loading") {
    StatsDashboardContent(
        state: .loading, period: .month, selectedDeck: nil,
        topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: false
    )
}

#Preview("Failed") {
    StatsDashboardContent(
        state: .failed("The collection is locked."), period: .month,
        selectedDeck: nil, topLevelDecks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: false
    )
}
#endif
