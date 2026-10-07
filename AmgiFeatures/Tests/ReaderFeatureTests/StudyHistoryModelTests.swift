import Testing
import AnkiKit
import AnkiClients
import AmgiAppCore
import AmgiUI
import Dependencies
import Foundation
@testable import ReaderFeature

@Suite @MainActor struct StudyHistoryModelTests {
    @Test func historicalReviewMatchesScheduledCountAndKeepsCandidatesSeparate() {
        let model = StudyLandingModel()
        model.dayOffset = 1
        model.spanHistory = StudyHistory(learningIds: [1], reviewIds: [2], newCandidateIds: [3], unresolved: [.init(cardId: 4, reason: .manualSchedule)], suspensionUnknownIds: [2, 3])
        #expect(model.spanRemainingRow?.search == "cid:1,2")
        #expect(model.spanRemainingRow?.reviewSearch == "(cid:1,2) -is:suspended -is:buried -deck:filtered")
        #expect(model.spanRemainingRow?.count == 2)
        #expect(model.spanRemainingRow?.isReconstructed == true)
        #expect(model.spanRemainingRow?.suspensionUnknownCount == 1)
        #expect(model.spanRemainingRow?.reschedulesByDefault == false)
        #expect(model.historyCardMix?.remainingLearn == 1)
        #expect(model.historyCardMix?.remainingReview == 1)
        #expect(model.historyCardMix?.newCandidates == 1)
        #expect(model.historyCardMix?.remainingTotal == 2)
        #expect(model.historyCardMix?.suspensionUnknown == 1)
    }

    @Test func todayAndFutureDoNotExposeHistoricalReview() {
        let model = StudyLandingModel()
        model.spanHistory = StudyHistory(learningIds: [1], reviewIds: [], newCandidateIds: [], unresolved: [])
        #expect(model.spanRemainingRow == nil)
        model.dayOffset = -1
        #expect(model.spanRemainingRow == nil)
    }

    @MainActor private final class Probe {
        var boundaries: [Int64] = []
        var scopes: [String] = []
        var searches = 0
    }

    private func model(probe: Probe, profile: ProfileContext? = nil) -> StudyLandingModel {
        var stats = StatsClient()
        stats.studyHistory = { scope, end, _ in
            await MainActor.run {
                probe.boundaries.append(end)
                probe.scopes.append(scope)
            }
            return StudyHistory(learningIds: [1, 1], reviewIds: [2], newCandidateIds: [3], unresolved: [], suspensionUnknownIds: [2, 3])
        }
        stats.dayMix = { _, _, _, _ in
            StudyDayMix(answeredNew: 0, answeredLearn: 0, answeredRelearn: 0,
                answeredReview: 0, answeredCards: 0, remainingLearn: 99, remainingReview: 99)
        }
        var cards = CardClient()
        cards.searchIds = { _, _ in
            await MainActor.run { probe.searches += 1 }
            return []
        }
        return withDependencies {
            $0.statsClient = stats
            $0.cardClient = cards
        } operation: {
            StudyLandingModel(profile: profile ?? AccountStore.shared.selectedContext)
        }
    }

    @Test func widerSpanUsesEndBoundaryAndKeepsCountListAgreement() async throws {
        let probe = Probe()
        let model = model(probe: probe)
        model.grain = .week
        model.dayOffset = 14
        let today = AnkiDay.start(of: Date(), rolloverHour: 4, calendar: .current)
        let offsets = StudySpan.weekOffsets(todayStart: today, anchor: 14, calendar: .current)
        let window = try #require(StudySpan.ratingWindow(offsets: offsets))
        let end = StudySpan.date(todayStart: today, offset: window.newest - 1, calendar: .current)
        await model.reloadSpanRows()
        #expect(probe.boundaries == [Int64(end.timeIntervalSince1970 * 1_000)])
        #expect(probe.scopes == [""])
        #expect(model.historyCardMix?.remainingLearn == 1)
        #expect(model.historyCardMix?.remainingReview == 1)
        #expect(model.historyCardMix?.newCandidates == 1)
        #expect(model.historyCardMix?.remainingTotal == 2)
        #expect(model.spanRemainingRow?.count == 2)
        #expect(model.spanRemainingRow?.search == "cid:1,2")
        let candidates = try #require(model.spanRows.first { $0.id == "history-new" })
        #expect(candidates.reschedulesByDefault == false)
        #expect(candidates.isReconstructed)
        #expect(candidates.suspensionUnknownCount == 1)
        #expect(candidates.search == "cid:3")
    }

    @Test func oldProfileModelCannotReadTheNewCollection() async {
        let probe = Probe()
        let stale = ProfileContext(id: "old-profile", displayName: "Old", selectionID: UUID())
        let model = model(probe: probe, profile: stale)
        await model.showHistory()
        #expect(probe.boundaries.isEmpty)
        #expect(probe.searches == 0)
        #expect(model.spanHistory == nil)
    }
}
