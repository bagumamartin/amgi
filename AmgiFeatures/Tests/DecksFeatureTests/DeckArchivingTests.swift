import AmgiAppShared
import AmgiUI
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
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

    @Test func archivedIDsSkipDueExemptAndEmptyDecks() async {
        let probe = SearchProbe()
        var client = CardClient()
        client.searchIds = { query, _ in
            probe.mark()
            let suspended = query.contains("is:suspended")
            if query.contains("Parked") {
                return (0..<(suspended ? 5 : 5)).map { CardID(Int64($0 + 1)) }
            }
            if query.contains("CaughtUp") {
                return (0..<(suspended ? 0 : 12)).map { CardID(Int64($0 + 1)) }
            }
            return []
        }
        let ids = await DeckArchiving.archivedIDs(
            in: [
                .init(id: DeckID(1), fullName: "Default", isFiltered: false, dueCount: 0),
                .init(id: DeckID(2), fullName: "Parked", isFiltered: false, dueCount: 0),
                .init(id: DeckID(3), fullName: "CaughtUp", isFiltered: false, dueCount: 0),
                .init(id: DeckID(4), fullName: "Custom Study Session", isFiltered: true, dueCount: 0),
                .init(id: DeckID(5), fullName: "DueToday", isFiltered: false, dueCount: 6),
            ],
            using: client
        )
        #expect(ids == [DeckID(2)])
        #expect(probe.count == 4)
    }

    @Test func archivedIDsReturnEmptyWithoutSearchingWhenNothingIsACandidate() async {
        let probe = SearchProbe()
        var client = CardClient()
        client.searchIds = { _, _ in
            probe.mark()
            return []
        }
        let ids = await DeckArchiving.archivedIDs(
            in: [
                .init(id: DeckID(1), fullName: "Default", isFiltered: false, dueCount: 0),
                .init(id: DeckID(5), fullName: "DueToday", isFiltered: false, dueCount: 6),
                .init(id: DeckID(4), fullName: "Custom Study Session", isFiltered: true, dueCount: 0),
            ],
            using: client
        )
        #expect(ids.isEmpty)
        #expect(probe.count == 0)
    }
}

private final class SearchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    func mark() {
        lock.lock()
        _count += 1
        lock.unlock()
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

@Suite struct DeckDetailModelArchivingTests {
    @MainActor
    @Test func parkedDirectChildrenAreArchivedExceptDefaultAndFiltered() async {
        let model = makeModel(
            parent: DeckInfo(id: DeckID(100), name: "Korean"),
            children: [
                node(id: 1, name: "Default", fullName: "Korean::Default"),
                node(id: 102, name: "Parked", fullName: "Korean::Parked"),
                node(id: 103, name: "CaughtUp", fullName: "Korean::CaughtUp"),
                node(id: 104, name: "Custom", fullName: "Korean::Custom", isFiltered: true),
                node(id: 105, name: "DueToday", fullName: "Korean::DueToday", newCount: 6),
            ],
            cardCounts: [
                "Korean::Default": (total: 8, suspended: 8),
                "Korean::Parked": (total: 5, suspended: 5),
                "Korean::CaughtUp": (total: 12, suspended: 0),
                "Korean::Custom": (total: 3, suspended: 3),
            ]
        )

        await model.loadChildren()

        #expect(model.archivedSubdeckIDs == [DeckID(102)])
        let activeNames = model.childDecks
            .filter { !model.archivedSubdeckIDs.contains($0.id) }
            .map(\.name)
        #expect(activeNames == ["Default", "CaughtUp", "Custom", "DueToday"])
    }

    @MainActor
    @Test func leafDeckHasNoArchivedChildren() async {
        let model = makeModel(
            parent: DeckInfo(id: DeckID(100), name: "Korean"),
            children: [],
            cardCounts: [:]
        )
        await model.loadChildren()
        #expect(model.childDecks.isEmpty)
        #expect(model.archivedSubdeckIDs.isEmpty)
    }

    @MainActor
    private func makeModel(
        parent: DeckInfo,
        children: [DeckTreeNode],
        cardCounts: [String: (total: Int, suspended: Int)]
    ) -> DeckDetailModel {
        var deckClient = DeckClient()
        deckClient.fetchTree = {
            [
                DeckTreeNode(
                    id: parent.id,
                    name: parent.name,
                    fullName: parent.name,
                    counts: parent.counts,
                    isFiltered: parent.isFiltered,
                    children: children
                )
            ]
        }
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
                DeckDetailModel(deck: parent)
            }
        }
    }

    private func node(
        id: Int64,
        name: String,
        fullName: String,
        newCount: Int = 0,
        isFiltered: Bool = false
    ) -> DeckTreeNode {
        DeckTreeNode(
            id: DeckID(id),
            name: name,
            fullName: fullName,
            counts: DeckCounts(newCount: newCount, learnCount: 0, reviewCount: 0),
            isFiltered: isFiltered
        )
    }
}
