import Testing
import AnkiKit
import AnkiClients
import AmgiAppCore
import AmgiUI
import Dependencies
import Foundation
@testable import ReaderFeature

@Suite @MainActor struct StudyLedgerModelTests {
    /// 30 due (10 new, 5 learning, 15 review); 18 studied; 12 left.
    nonisolated static func day(offset: Int, learning: [Int64] = [1], review: [Int64] = [2], uncertain: StudyLedger.Uncertain = .init()) -> StudyLedger.Day {
        StudyLedger.Day(
            offset: offset,
            due: .init(new: 10, learn: 5, review: 15),
            studied: .init(new: 0, learn: 4, review: 14, cards: 18, answers: 25, millis: 600_000),
            left: .init(new: 10, learn: learning.count, review: review.count),
            uncertain: uncertain,
            exact: uncertain == .init(),
            detail: .init(leftLearningIds: learning, leftReviewIds: review)
        )
    }

    @Test func pastDayOffersWhatWasLeftAndShowsDueStudiedLeft() {
        let model = StudyLandingModel()
        model.dayOffset = 1
        model.spanLedger = Self.day(offset: 1)
        #expect(model.spanRemainingRow?.search == "cid:1,2")
        #expect(model.spanRemainingRow?.reviewSearch == "(cid:1,2) -is:suspended -is:buried -deck:filtered")
        #expect(model.spanRemainingRow?.count == 2)
        #expect(model.spanRemainingRow?.isReconstructed == true)
        #expect(model.spanRemainingRow?.reschedulesByDefault == false)
        let ledger = model.historyLedger
        #expect(ledger?.due.total == 30)
        #expect(ledger?.studiedCards == 18)
        #expect(ledger?.left.total == 12)
        #expect(ledger?.isSingleDay == true)
        #expect(ledger?.isExact == true)
        #expect(ledger?.notes.isEmpty == true)
    }

    @Test func inexactDayNamesEachCause() {
        let uncertain = StudyLedger.Uncertain(incompleteLog: 2, manualSchedule: 1, suspensionUnknown: 3, limitsExceeded: ["Languages::French"])
        let notes = StudyLandingModel.ledgerNotes(Self.day(offset: 1, uncertain: uncertain))
        #expect(notes.count == 3)
        #expect(notes[0].contains("3"))
        #expect(notes[2].contains("French"))
        #expect(!notes[2].contains("Languages"))
    }

    @Test func todayAndFutureDoNotExposeHistoricalReview() {
        let model = StudyLandingModel()
        model.spanLedger = Self.day(offset: 0)
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
        var decks: [Int64] = []
        var searches = 0
    }

    private func model(probe: Probe, profile: ProfileContext? = nil) -> StudyLandingModel {
        var stats = StatsClient()
        stats.reviewTimes = { _, _, _ in [] }
        stats.studyLedger = { deckID, _, days, _ in
            await MainActor.run {
                probe.boundaries.append(days[0].endMs)
                probe.decks.append(deckID)
            }
            return StudyLedger(days: [Self.day(offset: days[0].offset)])
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

    @Test func widerSpanRebuildsItsLastDayAndKeepsCountListAgreement() async throws {
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
        #expect(probe.decks == [0])
        #expect(model.historyLedger?.isSingleDay == false)
        #expect(model.historyLedger?.left.total == 12)
        #expect(model.spanRemainingRow?.count == 2)
        #expect(model.spanRemainingRow?.search == "cid:1,2")
        let learning = try #require(model.spanRows.first { $0.id == "history-learning" })
        #expect(learning.search == "cid:1")
        #expect(learning.isReconstructed)
        #expect(!model.spanRows.contains { $0.id == "history-new" })
    }

    @Test func oldProfileModelCannotReadTheNewCollection() async {
        let probe = Probe()
        let stale = ProfileContext(id: "old-profile", displayName: "Old", selectionID: UUID())
        let model = model(probe: probe, profile: stale)
        await model.showHistory()
        #expect(probe.boundaries.isEmpty)
        #expect(probe.searches == 0)
        #expect(model.spanLedger == nil)
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
        stats.studyLedger = { _, _, days, _ in
            if days[0].offset == 1 { await gate.pause() }
            return StudyLedger(days: [Self.day(offset: days[0].offset)])
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
        #expect(model.spanLedger == nil)
        #expect(model.spanRows.contains { $0.id == "history-learning" })
        #expect(model.spanRows.contains { $0.id == "history-review" })
        #expect(model.spanRowsLoading)
        model.dayOffset = 2
        await model.reloadSpanRows()
        #expect(model.spanLedger?.offset == 2)
        #expect(!model.spanRowsLoading)
        await gate.resume()
        await oldRequest.value
        #expect(model.dayOffset == 2)
        #expect(model.spanLedger?.offset == 2)
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

    @Test func aDayThatCannotBeRebuiltSaysSoInsteadOfShowingZeros() async {
        struct Failure: Error {}
        var stats = StatsClient()
        stats.reviewTimes = { _, _, _ in [] }
        stats.studyLedger = { _, _, _, _ in throw Failure() }
        var cards = CardClient()
        cards.searchIds = { _, _ in [] }
        let model = withDependencies {
            $0.statsClient = stats
            $0.cardClient = cards
        } operation: { StudyLandingModel() }
        model.dayOffset = 1
        await model.reloadSpanRows()
        #expect(model.historyLedger == nil)
        #expect(model.spanRowsError != nil)
        #expect(model.spanRemainingRow == nil)
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
        stats.studyLedger = { _, _, days, _ in
            let calls = await MainActor.run {
                probe.boundaries.append(days[0].endMs)
                return probe.boundaries.count
            }
            if calls == 2 { await gate.pause() }
            return StudyLedger(days: [Self.day(offset: days[0].offset)])
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
        #expect(model.historyLedger?.left.total == 12)
        #expect(!model.spanRowsLoading)
        await gate.resume()
        await request.value
        #expect(probe.boundaries.count == 2)
        #expect(model.spanRemainingRow?.count == 2)
    }
}
