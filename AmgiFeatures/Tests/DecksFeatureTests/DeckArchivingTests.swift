import AmgiAppShared
import AmgiUI
import AnkiClients
import AnkiKit
import Dependencies
import Testing
@testable import DecksFeature

@Suite struct DeckArchivingTests {
    @Test func defaultAndFilteredDecksStayInLibrary() {
        #expect(DeckArchiving.isExempt(id: DeckID(1), isFiltered: false))
        #expect(DeckArchiving.isExempt(id: DeckID(99), isFiltered: true))
        #expect(!DeckArchiving.isExempt(id: DeckID(99), isFiltered: false))
    }

    @Test func emptyDecksAreNotArchived() {
        #expect(!DeckArchiving.isFullySuspended(totalCards: 0, suspendedCards: 0))
    }

    @Test func mixedSuspendIsNotArchived() {
        #expect(!DeckArchiving.isFullySuspended(totalCards: 10, suspendedCards: 4))
    }

    @Test func everyCardParkedIsArchived() {
        #expect(DeckArchiving.isFullySuspended(totalCards: 10, suspendedCards: 10))
        #expect(DeckArchiving.isFullySuspended(totalCards: 3, suspendedCards: 3))
    }
}

@Suite struct DeckListModelArchivingTests {
    @MainActor
    @Test func fullySuspendedDecksAreArchivedExceptDefaultAndFiltered() async {
        let model = makeModel(
            tree: [
                node(id: 1, name: "Default"),
                node(id: 2, name: "Parked"),
                node(id: 3, name: "CaughtUp"),
                node(id: 4, name: "Custom Study Session", isFiltered: true),
                node(id: 5, name: "DueToday", newCount: 6),
            ],
            cardCounts: [
                "Default": (total: 8, suspended: 8),
                "Parked": (total: 5, suspended: 5),
                "CaughtUp": (total: 12, suspended: 0),
                "Custom Study Session": (total: 3, suspended: 3),
            ]
        )

        await model.load(sortOrder: .collectionOrder)
        guard case .loaded(let rows, let hero, _) = model.state else {
            Issue.record("expected .loaded, got \(model.state)")
            return
        }

        let archived = rows.filter(\.isArchived).map(\.name)
        let active = rows.filter { !$0.isArchived }.map(\.name)
        #expect(archived == ["Parked"])
        #expect(active == ["Default", "CaughtUp", "Custom Study Session", "DueToday"])
        #expect(hero.deckCount == 4)
    }

    @MainActor
    private func makeModel(
        tree: [DeckTreeNode],
        cardCounts: [String: (total: Int, suspended: Int)]
    ) -> DeckListModel {
        var deckClient = DeckClient()
        deckClient.fetchTree = { tree }
        var cardClient = CardClient()
        cardClient.searchIds = { query, _ in
            let suspended = query.contains("is:suspended")
            for (name, counts) in cardCounts {
                let term = DeckSearch.term(name)
                if query == term || query.hasPrefix("\(term) ") {
                    let n = suspended ? counts.suspended : counts.total
                    return (0..<n).map { CardID(Int64($0 + 1)) }
                }
            }
            return []
        }
        return withDependencies {
            $0.deckClient = deckClient
            $0.cardClient = cardClient
            $0.statsClient = StatsClient(
                fetchGraphs: { _, _ in GraphsSnapshot() },
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

    private func node(
        id: Int64,
        name: String,
        newCount: Int = 0,
        isFiltered: Bool = false
    ) -> DeckTreeNode {
        DeckTreeNode(
            id: DeckID(id),
            name: name,
            fullName: name,
            counts: DeckCounts(newCount: newCount, learnCount: 0, reviewCount: 0),
            isFiltered: isFiltered
        )
    }
}
