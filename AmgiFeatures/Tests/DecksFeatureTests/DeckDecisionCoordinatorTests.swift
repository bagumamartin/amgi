import AnkiKit
import Foundation
import Testing
@testable import DecksFeature

@Suite struct DeckDecisionCoordinatorTests {
    private final class Collection {
        var metadata = DeckDecisionMetadata()
        var suspended: Set<Int64> = [3]
        var cards: Set<Int64> = [1, 2, 3]
        var restored: [Int64] = []
        var saved = 0
        var failSaveAt: Int?
        var failSuspend = false
        var deleted = false
        var queries: [String] = []
        var deck = DeckTreeNode(id: DeckID(7), name: "Deck", fullName: "Parent::Deck",
            cardCount: 3, uncappedCounts: .zero)
        enum Failure: Error { case injected }

        var operations: DeckDecisionOperations {
            DeckDecisionOperations(
                target: { _ in self.deck },
                search: { query in
                    self.queries.append(query)
                    return (query.contains("-is:suspended") ? self.cards.subtracting(self.suspended) : self.cards.intersection(self.suspended))
                        .sorted().map { CardID($0) }
                },
                save: { metadata in
                    self.saved += 1
                    if self.saved == self.failSaveAt { throw Failure.injected }
                    self.metadata = metadata
                },
                suspend: { cards in
                    if self.failSuspend { throw Failure.injected }
                    self.suspended.formUnion(cards.map(\.rawValue))
                },
                restore: { cards in
                    self.restored = cards.map(\.rawValue)
                    self.suspended.subtract(self.restored)
                },
                delete: { _ in self.deleted = true }
            )
        }
        func perform(_ mutation: DeckDecisionMutation) throws -> DeckDecisionResult {
            try DeckDecisionCoordinator.perform(mutation, metadata: metadata, using: operations)
        }
    }

    @Test func pauseRecordsOnlyPreviouslyActiveCardsAndScopeIncludesChildren() throws {
        let collection = Collection()
        collection.deck.children = [DeckTreeNode(id: DeckID(8), name: "Child", fullName: "Parent::Deck::Child", cardCount: 1)]
        let result = try collection.perform(.pause(DeckID(7)))
        #expect(result.collectionChanged)
        #expect(collection.suspended == [1, 2, 3])
        #expect(collection.metadata.entries["7"]?.pause?.cardIDs == [1, 2])
        #expect(collection.metadata.entries["7"]?.pause?.status == .confirmed)
        #expect(collection.queries == ["(did:7,8) -is:suspended"])
    }
    @Test func resumePreservesPreexistingIndividualSuspensions() throws {
        let collection = Collection()
        _ = try collection.perform(.pause(DeckID(7)))
        _ = try collection.perform(.resume(DeckID(7)))
        #expect(collection.restored == [1, 2])
        #expect(collection.suspended == [3])
        #expect(collection.metadata.entries["7"]?.pause == nil)
        #expect(collection.metadata.isSuppressed(id: 7, issue: "inactive", now: Date()))
    }
    @Test func resumeIgnoresCardsMovedOutOfTheDeckOrAlreadyRestored() throws {
        let collection = Collection()
        _ = try collection.perform(.pause(DeckID(7)))
        collection.cards.remove(1)
        collection.suspended.remove(2)
        _ = try collection.perform(.resume(DeckID(7)))
        #expect(collection.restored.isEmpty)
        #expect(collection.suspended.contains(3))
    }
    @Test func missingAndIncompleteRecordsAlwaysChooseCards() throws {
        let collection = Collection()
        #expect(try collection.perform(.resume(DeckID(7))).chooseCards)
        collection.metadata.entries["7"] = .init(pause: .init(cardIDs: [1], status: .pending))
        #expect(try collection.perform(.resume(DeckID(7))).chooseCards)
        collection.metadata.entries["7"]?.pause?.status = .resuming
        #expect(try collection.perform(.resume(DeckID(7))).chooseCards)
        #expect(collection.restored.isEmpty)
    }
    @Test func recoveryWriteFailurePreventsSuspension() {
        let collection = Collection()
        collection.failSaveAt = 1
        #expect(throws: Collection.Failure.self) { try collection.perform(.pause(DeckID(7))) }
        #expect(collection.suspended == [3])
        #expect(collection.metadata.entries.isEmpty)
    }
    @Test func failedSuspensionLeavesAnIncompleteRecord() {
        let collection = Collection()
        collection.failSuspend = true
        #expect(throws: DeckDecisionFailure.self) { try collection.perform(.pause(DeckID(7))) }
        #expect(collection.metadata.entries["7"]?.pause?.status == .pending)
        #expect(collection.suspended == [3])
    }
    @Test func finalRecordFailureReportsPartialSuccessAndRequiresSelection() throws {
        let collection = Collection()
        collection.failSaveAt = 2
        do {
            _ = try collection.perform(.pause(DeckID(7)))
            Issue.record("Expected final record failure")
        } catch let failure as DeckDecisionFailure {
            #expect(failure.collectionChanged)
        }
        #expect(collection.suspended == [1, 2, 3])
        #expect(try collection.perform(.resume(DeckID(7))).chooseCards)
    }
    @Test func resumeFinalWriteFailureCannotRepeatAnUncertainRestore() throws {
        let collection = Collection()
        _ = try collection.perform(.pause(DeckID(7)))
        collection.failSaveAt = 4
        #expect(throws: DeckDecisionFailure.self) { try collection.perform(.resume(DeckID(7))) }
        #expect(collection.metadata.entries["7"]?.pause?.status == .resuming)
        #expect(collection.suspended == [3])
        #expect(try collection.perform(.resume(DeckID(7))).chooseCards)
    }
    @Test func deletionRechecksCardCountAndName() throws {
        let collection = Collection()
        #expect(throws: DeckDecisionFailure.self) {
            try collection.perform(.delete(DeckID(7), expectedName: "Parent::Deck", expectedCardCount: 0))
        }
        #expect(!collection.deleted)
        _ = try collection.perform(.delete(DeckID(7), expectedName: "Parent::Deck", expectedCardCount: 3))
        #expect(collection.deleted)
    }
    @Test func deletionRejectsAnUnconfirmedSubdeckEvenWithTheSameCardTotal() {
        let collection = Collection()
        collection.deck.children = [DeckTreeNode(id: DeckID(8), name: "New child", fullName: "Parent::Deck::New child", cardCount: 0)]
        #expect(throws: DeckDecisionFailure.self) {
            try collection.perform(.delete(DeckID(7), expectedName: "Parent::Deck", expectedCardCount: 3))
        }
        #expect(!collection.deleted)
    }
    @Test func defaultAndFilteredCannotBeMutated() {
        let collection = Collection()
        #expect(throws: DeckDecisionFailure.self) { try collection.perform(.pause(DeckID(1))) }
        collection.deck.isFiltered = true
        #expect(throws: DeckDecisionFailure.self) { try collection.perform(.pause(DeckID(7))) }
        #expect(collection.suspended == [3])
    }
}
