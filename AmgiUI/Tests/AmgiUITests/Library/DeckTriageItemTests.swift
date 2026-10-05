import Testing
@testable import AmgiUI

@Suite struct DeckTriageItemTests {
    private func item(issue: DeckTriageIssue, due: Int = 20, id: Int64 = 7, resume: Bool = false) -> DeckTriageItem {
        DeckTriageItem(row: DeckRowViewData(id: id, name: "한국어", fullName: "Languages::한국어",
            newCount: due, learnCount: 0, reviewCount: 0, isFiltered: false, subdeckCount: 0,
            cardCount: 400, availableNewCount: 340, waitingCount: 340), issue: issue, canResumeDirectly: resume)
    }
    @Test func inactiveOffersAnActualChoice() {
        let value = item(issue: .neglected(daysAgo: 47))
        #expect(value.actions == [.study, .pause])
        #expect(value.evidence == "Last studied 47 days ago · 340 cards waiting")
    }
    @Test func blockedStudyOffersSettings() {
        #expect(item(issue: .neverStarted, due: 0).actions == [.pace, .pause])
    }
    @Test func defaultCannotBePausedOrDeleted() {
        #expect(item(issue: .neglected(daysAgo: 40), id: 1).actions == [.study])
        #expect(item(issue: .empty, id: 1).actions == [.addCards])
    }
    @Test func backlogOffersPaceAndAcknowledgment() {
        #expect(item(issue: .newBacklog(perDay: 20, daysToClear: 17)).actions == [.pace, .keepPace])
    }
    @Test func pausedNeedsProvenanceForDirectResume() {
        #expect(item(issue: .parked).actions == [.chooseCards, .keepPaused])
        #expect(item(issue: .parked, resume: true).actions == [.resume, .keepPaused])
        #expect(item(issue: .parked).evidence == "All cards suspended")
    }
    @Test func noLifetimeClaimsForUnusedCards() {
        #expect(item(issue: .neverStarted).evidence == "340 new cards waiting")
    }
    @Test func focusSurvivesEnrichmentAndFallsBackAfterResolution() {
        let first = item(issue: .empty, id: 7)
        let second = item(issue: .empty, id: 8)
        #expect(DeckTriageData(items: [second, first], focusedID: 7).focusedItem?.id == 7)
        #expect(DeckTriageData(items: [second], focusedID: 7).focusedItem?.id == 8)
    }
    @Test func readinessAndEmptyAreIndependent() {
        #expect(!DeckTriageData.unresolved.isHidden)
        #expect(DeckTriageData.resolvedEmpty.isHidden)
        #expect(DeckTriageData(items: [], readiness: .unavailable).isHidden)
        #expect(!DeckTriageData.sample.isHidden)
    }
}
