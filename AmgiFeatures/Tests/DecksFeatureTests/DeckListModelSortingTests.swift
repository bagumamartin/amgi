import AmgiAppShared
import AmgiUI
import AnkiClients
import AnkiKit
import Dependencies
import Testing
@testable import DecksFeature

@Suite struct DeckListModelSortingTests {
    @MainActor
    @Test func loadAndResortReorderLibraryRows() async {
        let model = makeModel(tree: [
            node(id: 1, name: "Zed", newCount: 1),
            node(id: 2, name: "Alpha", newCount: 10),
            node(id: 3, name: "Mid", newCount: 5),
        ])

        await model.load(sortOrder: .collectionOrder)
        #expect(loadedNames(model) == ["Zed", "Alpha", "Mid"])

        model.resort(sortOrder: .alphabetical)
        #expect(loadedNames(model) == ["Alpha", "Mid", "Zed"])

        model.resort(sortOrder: .mostDue)
        #expect(loadedNames(model) == ["Alpha", "Mid", "Zed"])
    }

    @MainActor
    @Test func mostUsedOrdersByReviewVolume() async {
        let model = makeModel(
            tree: [
                node(id: 1, name: "Rare"),
                node(id: 2, name: "Daily"),
                node(id: 3, name: "Weekly"),
            ],
            reviewsByDeck: [
                "Daily": 40,
                "Weekly": 8,
                "Rare": 1,
            ]
        )

        await model.load(sortOrder: .mostUsed)
        #expect(loadedNames(model) == ["Daily", "Weekly", "Rare"])
    }

    @MainActor
    private func loadedNames(_ model: DeckListModel) -> [String] {
        guard case .loaded(let rows, _, _) = model.state else {
            Issue.record("expected .loaded, got \(model.state)")
            return []
        }
        return rows.map(\.name)
    }

    @MainActor
    private func makeModel(
        tree: [DeckTreeNode],
        reviewsByDeck: [String: Int] = [:]
    ) -> DeckListModel {
        var deckClient = DeckClient()
        deckClient.fetchTree = { tree }
        var cardClient = CardClient()
        cardClient.searchIds = { _, _ in [] }
        return withDependencies {
            $0.deckClient = deckClient
            $0.cardClient = cardClient
            $0.statsClient = StatsClient(
                fetchGraphs: { search, _ in
                    if search.isEmpty { return GraphsSnapshot() }
                    let name = reviewsByDeck.keys.first { search == DeckUsageRanking.deckSearch(fullName: $0) }
                    return graphs(reviewsToday: name.map { reviewsByDeck[$0] ?? 0 } ?? 0)
                },
                graduatedToday: { _ in 0 },
                learningDueToday: { _ in 0 },
                lastRating: { _ in nil }
            )
        } operation: {
            let store = CollectionStore()
            return withDependencies {
                $0.collectionStore = store
            } operation: {
                DeckListModel()
            }
        }
    }

    private func node(id: Int64, name: String, newCount: Int = 0) -> DeckTreeNode {
        DeckTreeNode(
            id: DeckID(id),
            name: name,
            fullName: name,
            counts: DeckCounts(newCount: newCount, learnCount: 0, reviewCount: 0)
        )
    }

    private func graphs(reviewsToday: Int) -> GraphsSnapshot {
        var snapshot = GraphsSnapshot()
        if reviewsToday > 0 {
            snapshot.reviews.count = [
                0: .init(learn: reviewsToday, relearn: 0, young: 0, mature: 0, filtered: 0)
            ]
        }
        return snapshot
    }
}
