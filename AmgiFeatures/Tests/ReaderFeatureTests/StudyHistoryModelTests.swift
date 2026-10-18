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

    @Test func hourCountsBucketAnswersByLocalClockHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        // 2026-10-17 in Paris (UTC+2): 03:59, 04:00, 04:30 and 23:15 local.
        let at = { (hour: Int, minute: Int) -> Int64 in
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: hour, minute: minute))!
            return Int64(date.timeIntervalSince1970 * 1_000)
        }
        let counts = StudyLandingModel.hourCounts(
            [at(3, 59), at(4, 0), at(4, 30), at(23, 15)],
            calendar: calendar
        )
        #expect(counts.count == 24)
        #expect(counts[3] == 1)
        #expect(counts[4] == 2)
        #expect(counts[23] == 1)
        #expect(counts.reduce(0, +) == 4)
    }

    @MainActor private final class Probe {
        var boundaries: [Int64] = []
        var scopes: [String] = []
        var searches = 0
    }

    private func model(probe: Probe, profile: ProfileContext? = nil) -> StudyLandingModel {
        var stats = StatsClient()
        stats.reviewTimes = { _, _, _ in [] }
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
    @Test func revisitingPeriodUsesCompleteCachedResult() async {
        let probe = Probe()
        let model = model(probe: probe)
        model.dayOffset = 1
        await model.reloadSpanRows()
        let firstSearches = probe.searches
        model.dayOffset = 2
        await model.reloadSpanRows()
        let searches = probe.searches
        model.dayOffset = 1
        await model.reloadSpanRows()
        #expect(probe.boundaries.count == 2)
        #expect(firstSearches > 0)
        #expect(probe.searches == searches)
        #expect(model.spanRemainingRow?.count == 2)
        #expect(!model.spanRowsLoading)
        #expect(!model.spanDeckRowsLoading)
    }

    private actor Gate {
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var isStarted = false

        func pause() async {
            await withCheckedContinuation { continuation in
                release = continuation
                isStarted = true
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if isStarted { return }
            await withCheckedContinuation { started = $0 }
        }

        func resume() {
            release?.resume()
            release = nil
        }
    }

    @Test func partialHistoryStaysHiddenAndOldSelectionCannotPublish() async {
        let gate = Gate()
        var stats = StatsClient()
        stats.reviewTimes = { _, _, _ in [] }
        stats.studyHistory = { _, _, _ in
            StudyHistory(learningIds: [1], reviewIds: [2], newCandidateIds: [], unresolved: [])
        }
        stats.dayMix = { _, _, _, newest in
            if newest == 1 { await gate.pause() }
            return StudyDayMix(answeredNew: newest, answeredLearn: 0, answeredRelearn: 0,
                answeredReview: 0, answeredCards: newest, remainingLearn: 0, remainingReview: 0)
        }
        var cards = CardClient()
        cards.searchIds = { _, _ in [] }
        let model = withDependencies {
            $0.statsClient = stats
            $0.cardClient = cards
        } operation: { StudyLandingModel() }
        model.dayOffset = 1
        let oldRequest = Task { await model.reloadSpanRows() }
        await gate.waitUntilStarted()
        #expect(model.spanHistory == nil)
        #expect(model.spanRows.contains { $0.id == "history-learning" })
        #expect(model.spanRows.contains { $0.id == "history-review" })
        #expect(model.spanRows.contains { $0.id == "history-new" })
        #expect(model.spanRowsLoading)
        model.dayOffset = 2
        await model.reloadSpanRows()
        let selectedMix = model.spanMix
        #expect(model.spanHistory != nil)
        #expect(!model.spanRowsLoading)
        await gate.resume()
        await oldRequest.value
        #expect(model.dayOffset == 2)
        #expect(model.spanMix?.answeredNew == selectedMix?.answeredNew)
        #expect(!model.spanRowsLoading)
    }

    @Test func adjacentPrefetchKeepsSelectionAndMakesNextStepImmediate() async {
        let probe = Probe()
        let model = model(probe: probe)
        model.dayOffset = 2
        await model.reloadSpanRows()
        let selectedSearch = model.spanRemainingRow?.search
        await model.prefetchAdjacentSpans()
        #expect(probe.boundaries.count == 3)
        #expect(model.dayOffset == 2)
        #expect(model.spanRemainingRow?.search == selectedSearch)
        #expect(!model.spanRowsLoading)
        let searches = probe.searches
        model.step(towardsPast: true)
        #expect(model.dayOffset == 3)
        #expect(!model.spanRowsLoading)
        #expect(model.spanRemainingRow?.count == 2)
        #expect(probe.searches == searches)
    }

    @Test(.timeLimit(.minutes(1))) func historyAndRecordedMixStartIndependently() async {
        let historyGate = Gate()
        let mixGate = Gate()
        var stats = StatsClient()
        stats.reviewTimes = { _, _, _ in [] }
        stats.studyHistory = { _, _, _ in
            await historyGate.pause()
            return StudyHistory(learningIds: [1], reviewIds: [], newCandidateIds: [], unresolved: [])
        }
        stats.dayMix = { _, _, _, _ in
            await mixGate.pause()
            return StudyDayMix(answeredNew: 0, answeredLearn: 0, answeredRelearn: 0,
                answeredReview: 0, answeredCards: 0, remainingLearn: 0, remainingReview: 0)
        }
        var cards = CardClient()
        cards.searchIds = { _, _ in [] }
        let model = withDependencies {
            $0.statsClient = stats
            $0.cardClient = cards
        } operation: { StudyLandingModel() }
        model.dayOffset = 1
        let request = Task { await model.reloadSpanRows() }
        await historyGate.waitUntilStarted()
        await mixGate.waitUntilStarted()
        #expect(model.spanRowsLoading)
        #expect(model.spanHistory == nil)
        await historyGate.resume()
        await mixGate.resume()
        await request.value
        #expect(model.spanRemainingRow?.count == 1)
        #expect(!model.spanRowsLoading)
    }

    @Test func futureKeepsDueRowMountedWithoutPresentingAnUnknownZero() async {
        let gate = Gate()
        var cards = CardClient()
        cards.searchIds = { _, _ in
            await gate.pause()
            return [CardID(1)]
        }
        let model = withDependencies {
            $0.cardClient = cards
        } operation: { StudyLandingModel() }
        model.dayOffset = -1
        let request = Task { await model.reloadSpanRows() }
        await gate.waitUntilStarted()
        #expect(model.spanRowsLoading)
        #expect(model.spanRows.first?.id == "due")
        #expect(!model.spanHeroTitle.contains("0"))
        await gate.resume()
        await request.value
        #expect(model.spanHeroCount == 1)
        #expect(!model.spanRowsLoading)
    }

    @Test func refreshingSamePeriodRetainsKnownValues() async {
        let gate = Gate()
        let probe = Probe()
        var stats = StatsClient()
        stats.reviewTimes = { _, _, _ in [] }
        stats.studyHistory = { _, end, _ in
            let calls = await MainActor.run {
                probe.boundaries.append(end)
                return probe.boundaries.count
            }
            if calls == 2 { await gate.pause() }
            return StudyHistory(learningIds: [1], reviewIds: [2], newCandidateIds: [], unresolved: [])
        }
        stats.dayMix = { _, _, _, _ in
            StudyDayMix(answeredNew: 0, answeredLearn: 0, answeredRelearn: 0,
                answeredReview: 0, answeredCards: 0, remainingLearn: 0, remainingReview: 0)
        }
        var cards = CardClient()
        cards.searchIds = { _, _ in [] }
        let model = withDependencies {
            $0.statsClient = stats
            $0.cardClient = cards
        } operation: { StudyLandingModel() }
        model.dayOffset = 1
        await model.reloadSpanRows()
        let request = Task { await model.reloadSpanRows(refresh: true) }
        await gate.waitUntilStarted()
        #expect(model.spanRemainingRow?.count == 2)
        #expect(model.historyCardMix?.remainingTotal == 2)
        #expect(!model.spanRowsLoading)
        await gate.resume()
        await request.value
        #expect(probe.boundaries.count == 2)
        #expect(model.spanRemainingRow?.count == 2)
    }

}
