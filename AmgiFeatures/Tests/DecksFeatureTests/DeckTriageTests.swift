import AmgiUI
import AnkiKit
import Foundation
import Testing
@testable import DecksFeature

@Suite struct DeckTriageTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func row(id: Int64 = 7, due: Int = 20, cards: Int? = 500, new: Int? = 20,
                     waiting: Int? = 50, archived: Bool = false, filtered: Bool = false) -> DeckRowViewData {
        DeckRowViewData(id: id, name: "Deck", fullName: "Deck", newCount: due,
            learnCount: 0, reviewCount: 0, isFiltered: filtered, subdeckCount: 0,
            isArchived: archived, cardCount: cards, availableNewCount: new, waitingCount: waiting)
    }
    private func rank(days: Int? = nil) -> DeckUsageRank {
        DeckUsageRank(reviewTotal: days == nil ? 0 : 100, lastActiveOffset: days.map { -$0 } ?? .min, weightedScore: 0)
    }
    private func matured(_ id: Int64, issue: String) -> DeckDecisionMetadata {
        var metadata = DeckDecisionMetadata()
        metadata.observe([id: issue], existingIDs: [id], now: now.addingTimeInterval(-7 * 86_400))
        return metadata
    }
    @Test func inactivityBoundaryUsesUncappedWaitingCounts() {
        let value = row(due: 0, waiting: 200)
        #expect(DeckTriage.issue(for: value, rank: rank(days: 30), newPerDay: nil) == .neglected(daysAgo: 30))
        #expect(DeckTriage.issue(for: value, rank: rank(days: 29), newPerDay: nil) == nil)
    }
    @Test func nothingDueDoesNotMeanEmpty() {
        #expect(DeckTriage.issue(for: row(due: 0, cards: 500, new: 0, waiting: 0), rank: rank(), newPerDay: nil) == nil)
        #expect(DeckTriage.issue(for: row(due: 0, cards: nil), rank: rank(), newPerDay: nil) == nil)
        #expect(DeckTriage.issue(for: row(due: 0, cards: 0), rank: nil, newPerDay: nil) == .empty)
    }
    @Test func unusedAndEmptyWaitSevenDays() {
        let value = row(cards: 340, new: 340, waiting: 340)
        #expect(DeckTriage.items(rows: [value], ranks: [7: rank()], archived: [], newPerDay: [:], now: now).isEmpty)
        let metadata = matured(7, issue: "unused")
        let items = DeckTriage.items(rows: [value], ranks: [7: rank()], archived: [], newPerDay: [:], metadata: metadata, now: now)
        #expect(items.first?.issue == .neverStarted)
        let empty = row(due: 0, cards: 0)
        #expect(DeckTriage.items(rows: [empty], ranks: [:], archived: [], newPerDay: [:], metadata: matured(7, issue: "empty"), now: now).first?.issue == .empty)
    }
    @Test func failedHistoryIsUnknown() {
        #expect(DeckTriage.issue(for: row(), rank: nil, newPerDay: nil) == nil)
        #expect(DeckTriage.observations(rows: [row()], ranks: [:], newPerDay: [:]).isEmpty)
    }
    @Test func backlogUsesActualNewCardsInsteadOfTodaysTwenty() {
        let value = row(due: 20, new: 401)
        #expect(DeckTriage.issue(for: value, rank: rank(days: 1), newPerDay: 20) == .newBacklog(perDay: 20, daysToClear: 21))
        #expect(DeckTriage.issue(for: value, rank: nil, newPerDay: 20) == .newBacklog(perDay: 20, daysToClear: 21))
    }
    @Test func zeroUnknownAndSmallPacesDoNotInventProjections() {
        let value = row(new: 500)
        #expect(DeckTriage.issue(for: value, rank: rank(days: 1), newPerDay: 0) == nil)
        #expect(DeckTriage.issue(for: value, rank: rank(days: 1), newPerDay: nil) == nil)
        #expect(DeckTriage.issue(for: row(new: 100), rank: rank(days: 1), newPerDay: 20) == nil)
        #expect(DeckTriage.issue(for: row(new: 60), rank: rank(days: 1), newPerDay: 1) == nil)
    }
    @Test func noAutomaticPausedFilteredOrDefaultCleanup() {
        #expect(DeckTriage.issue(for: row(archived: true), rank: rank(days: 100), newPerDay: nil) == nil)
        #expect(DeckTriage.issue(for: row(filtered: true), rank: rank(days: 100), newPerDay: nil) == nil)
        #expect(DeckTriage.issue(for: row(id: 1, cards: 0), rank: rank(), newPerDay: nil) == nil)
        #expect(DeckTriage.items(rows: [row()], ranks: [7: rank(days: 100)], archived: [DeckID(7)], newPerDay: [:]).isEmpty)
    }
    @Test func queueIsCompleteAndSortedDeterministically() {
        let rows = (2...11).map { row(id: Int64($0)) }
        let ranks = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, rank(days: Int($0.id) + 30)) })
        let items = DeckTriage.items(rows: rows, ranks: ranks, archived: [], newPerDay: [:])
        #expect(items.count == 10)
        #expect(items.map(\.id) == Array((2...11).reversed()).map { Int64($0) })
    }
    @Test func deferralExpiresAtItsExactBoundary() {
        var metadata = DeckDecisionMetadata()
        metadata.entries["7"] = .init(suppressedUntil: ["inactive": now.addingTimeInterval(7 * 86_400)])
        #expect(DeckTriage.items(rows: [row()], ranks: [7: rank(days: 100)], archived: [], newPerDay: [:], metadata: metadata, now: now).isEmpty)
        #expect(!DeckTriage.items(rows: [row()], ranks: [7: rank(days: 100)], archived: [], newPerDay: [:], metadata: metadata, now: now.addingTimeInterval(7 * 86_400)).isEmpty)
    }
    @Test func graceResetsWhenConditionEnds() {
        var metadata = matured(7, issue: "empty")
        metadata.observe([7: ""], existingIDs: [7], now: now)
        metadata.observe([7: "empty"], existingIDs: [7], now: now.addingTimeInterval(1))
        #expect(!metadata.pastGrace(id: 7, issue: "empty", now: now.addingTimeInterval(2)))
    }
    @Test func inventoryResetsEmptyGraceEvenWhenHistoryFails() {
        var metadata = matured(7, issue: "empty")
        let observations = DeckTriage.observations(rows: [row()], ranks: [:], newPerDay: [:], metadata: metadata)
        metadata.observe(observations, existingIDs: [7], now: now)
        metadata.observe([7: "empty"], existingIDs: [7], now: now.addingTimeInterval(1))
        #expect(!metadata.pastGrace(id: 7, issue: "empty", now: now.addingTimeInterval(2)))
        let unused = matured(7, issue: "unused")
        #expect(DeckTriage.observations(rows: [row(cards: 340, new: 340)], ranks: [:], newPerDay: [:], metadata: unused).isEmpty)
    }
    @Test func metadataRoundTripsAcrossRelaunchAndCollectionsStayIndependent() throws {
        var metadata = matured(7, issue: "unused")
        metadata.entries["7"]?.suppressedUntil["unused"] = now.addingTimeInterval(7 * 86_400)
        let copy = try JSONDecoder().decode(DeckDecisionMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(copy == metadata)
        #expect(copy.isSuppressed(id: 7, issue: "unused", now: now))
        #expect(!DeckDecisionMetadata().isSuppressed(id: 7, issue: "unused", now: now))
    }
}
