import Testing
import SwiftUI
import Dependencies
import AnkiClients
import AnkiKit
import AnkiServices
@testable import AmgiApp

// MARK: - ReviewSessionTests
// Lifted from ~/Clones/amgi/AnkiApp/Sources/Review/ReviewSessionTests.swift (82 LOC)
// Adapted to our architecture: @MainActor class, async revealAnswer(), swift-dependencies mocking.
//
// Migrated from XCTest -> Swift Testing. Per-test setUp/tearDown is replaced
// by per-instance `init` — Swift Testing creates a fresh `ReviewSessionTests`
// instance for every `@Test` method, so `session` is reinitialised cleanly.

@MainActor
@Suite struct ReviewSessionTests {
    let session: ReviewSession

    init() {
        session = ReviewSession(deckId: DeckID(1))
    }

    // MARK: - Deferred from fork

    // DEFERRED: fork's testCurrentCardInitiallyNil / testCurrentCardPublicAccess /
    // testCurrentCardStructure test `session.currentCard` — a public property in the
    // fork's ReviewSession. Our ReviewSession exposes `currentCardOrdinal: UInt32`
    // but keeps `currentQueuedCard` private. Exposing it would require a public accessor
    // that PR 1a did not add. Use `currentCardOrdinal == 0` as a proxy.
    // PR 1a defer: add `public private(set) var currentCard: QueuedReviewCard?` when needed.

    // MARK: - Property Exposure Tests

    /// currentCardOrdinal should be 0 before the session starts (maps to fork's currentCard == nil).
    @Test func currentCardOrdinalInitiallyZero() {
        #expect(session.currentCardOrdinal == 0,
                "currentCardOrdinal should be 0 before session starts")
    }

    // MARK: - Initial State Tests

    /// Session stats should all be zero-initialised (mirrors fork's testSessionStatsInitialized).
    @Test func sessionStatsInitialized() {
        #expect(session.sessionStats.reviewed == 0, "Initial reviewed count should be 0")
        #expect(session.sessionStats.correct == 0, "Initial correct count should be 0")
        #expect(session.sessionStats.totalTimeMs == 0, "Initial time should be 0")
    }

    /// Remaining counts should be zero before start() (mirrors fork's testRemainingCountsInitialized).
    @Test func remainingCountsInitialized() {
        #expect(session.remainingCounts.newCount == 0)
        #expect(session.remainingCounts.learnCount == 0)
        #expect(session.remainingCounts.reviewCount == 0)
    }

    /// nextIntervals should be empty before any card is loaded (mirrors fork's testNextIntervalsStructure).
    @Test func nextIntervalsStructure() {
        #expect(session.nextIntervals.isEmpty,
                "nextIntervals should be empty initially")
    }

    /// isFinished should be false before start() (mirrors fork's testIsFinishedInitiallyFalse).
    @Test func isFinishedInitiallyFalse() {
        #expect(!session.isFinished, "Session should not be finished initially")
    }

    /// showAnswer should be false before any card is loaded (mirrors fork's testShowAnswerInitiallyFalse).
    @Test func showAnswerInitiallyFalse() {
        #expect(!session.showAnswer, "Answer should not be visible initially")
    }

    // MARK: - Additional initial-state checks (not in fork; added to fill gaps)

    @Test func canUndoInitiallyFalse() {
        #expect(!session.canUndo,
                "canUndo should be false before any card is answered")
    }

    @Test func frontHTMLInitiallyEmpty() {
        #expect(session.frontHTML.isEmpty,
                "frontHTML should be empty before session starts")
    }

    @Test func backHTMLInitiallyEmpty() {
        #expect(session.backHTML.isEmpty,
                "backHTML should be empty before session starts")
    }

    @Test func cardCSSInitiallyEmpty() {
        #expect(session.cardCSS.isEmpty,
                "cardCSS should be empty before session starts")
    }

    @Test func requiresTypedAnswerInputInitiallyFalse() {
        #expect(!session.requiresTypedAnswerInput,
                "requiresTypedAnswerInput should be false initially")
    }

    // MARK: - start() with empty queue

    /// When the scheduler returns an empty queue, start() should mark the session finished.
    /// start() now runs its backend chain off the main actor in an internal Task, so the
    /// assertion waits for that work to settle.
    @Test func startWithEmptyQueueFinishesSession() async throws {
        // Queue-derived counts, not the preview client's (learningDueToday: 3):
        // the session's refineRemainingLearning overwrites the learn count
        // with whatever this returns.
        var stats = StatsClient.previewValue
        stats.learningDueToday = { _ in 0 }
        try await withDependencies {
            $0.statsClient = stats
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [], newCount: 0, learningCount: 0, reviewCount: 0)
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(42))
            s.start()
            await waitForSettled(s)
            #expect(s.isFinished,
                    "Session with empty queue should be finished after start()")
            #expect(s.remainingCounts == .zero)
            #expect(!s.isAdvancing, "isAdvancing should clear once start() settles")
        }
    }

    // MARK: - revealAnswer() sets showAnswer

    /// revealAnswer() when there is no typed-answer placeholder should set showAnswer = true.
    /// Tests the async path without needing a running card queue.
    @Test func revealAnswerSetsShowAnswer() async {
        // No typedAnswerState is set (no cards loaded), so revealAnswer() takes
        // the non-typed branch and immediately sets showAnswer = true.
        #expect(!session.showAnswer)
        await session.revealAnswer()
        #expect(session.showAnswer,
                "showAnswer should be true after revealAnswer() with no typed-answer state")
    }

    // MARK: - Audio / Chrome state (Task 2)

    @Test func updateAudioPlayingFlipsObservableFlag() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(!session.isAudioPlaying)
        session.updateAudioPlaying(true)
        #expect(session.isAudioPlaying)
        session.updateAudioPlaying(false)
        #expect(!session.isAudioPlaying)
    }

    @Test func updateCardChromeStoresColorAndDarkness() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(session.cardChromeColor == .clear)
        #expect(!session.cardChromeIsDark)
        session.updateCardChrome(color: PlatformColor.red, isDark: false)
        #expect(session.cardChromeColor == Color(platformColor: PlatformColor.red))
        #expect(!session.cardChromeIsDark)
        session.updateCardChrome(color: PlatformColor.black, isDark: true)
        #expect(session.cardChromeColor == Color(platformColor: PlatformColor.black))
        #expect(session.cardChromeIsDark)
    }

    // MARK: - Replay / Stop-audio bump mutators (Task 3)

    @Test func bumpReplayRequestIncrementsCounter() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(session.replayRequestID == 0)
        session.bumpReplayRequest()
        #expect(session.replayRequestID == 1)
        session.bumpReplayRequest()
        #expect(session.replayRequestID == 2)
    }

    @Test func bumpStopAudioRequestIncrementsCounter() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(session.stopAudioRequestID == 0)
        session.bumpStopAudioRequest()
        #expect(session.stopAudioRequestID == 1)
    }

    // MARK: - currentNote cache + TemplateTarget (Task 4)

    @Test func currentNoteCachedOnAdvance() async throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let callCounter = Counter()
        let stubNote = NoteRecord(
            id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0,
            flds: "", sfld: "", csum: 0
        )
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.notesService.getNote = { noteId in
                callCounter.value += 1
                #expect(noteId == NoteID(100))
                return stubNote
            }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "<p>front</p>", backHTML: "<p>back</p>", cardCSS: "")
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            await waitForSettled(session)
            #expect(session.currentNote == stubNote)
            #expect(callCounter.value == 1, "getNote should be called exactly once per advance")

            // Re-observe currentNote — must not trigger additional fetches
            _ = session.currentNote
            _ = session.currentNote
            #expect(callCounter.value == 1, "currentNote is cached, not refetched on observation")
        }
    }

    @Test func currentTemplateTargetDerivedFromCachedNoteAndCard() async throws {
        let stubNote = NoteRecord(
            id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0,
            flds: "", sfld: "", csum: 0
        )
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 3)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.notesService.getNote = { _ in stubNote }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            await waitForSettled(session)
            let target = session.currentTemplateTarget
            #expect(target != nil)
            #expect(target?.notetypeId == NotetypeID(200))
            #expect(target?.ordinal == 3)
        }
    }

    // MARK: - Full audio/chrome round-trip (Task 11)

    @Test func fullAudioAndChromeRoundTrip() async throws {
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )
        let stubNote = NoteRecord(id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.notesService.getNote = { _ in stubNote }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            await waitForSettled(session)

            // Audio start
            session.updateAudioPlaying(true)
            #expect(session.isAudioPlaying)

            // Capture baseline: advance() already bumped stopAudioRequestID once on card load
            let stopBaselineID = session.stopAudioRequestID

            // User taps replay-while-playing → stop bump (toolbar logic, here exercised manually)
            session.bumpStopAudioRequest()
            #expect(session.stopAudioRequestID == stopBaselineID + 1)

            // JS replies to amgiStopAllAudio → onAudioStateChange(false)
            session.updateAudioPlaying(false)
            #expect(!session.isAudioPlaying)

            // User taps replay again → replay bump
            session.bumpReplayRequest()
            #expect(session.replayRequestID == 1)

            // JS reports a card-bg color
            session.updateCardChrome(color: PlatformColor.systemBlue, isDark: false)
            #expect(session.cardChromeColor == Color(platformColor: PlatformColor.systemBlue))
        }
    }

    // MARK: - refreshAfterEdit() (Task 5)

    @Test func refreshAfterEditRerendersCurrentCardWithoutAdvancing() async throws {
        final class State: @unchecked Sendable {
            var renderCallCount = 0
            var noteFields = "old front\u{1f}old back"
        }
        let state = State()
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.notesService.getNote = { _ in
                NoteRecord(id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0, flds: state.noteFields, sfld: "", csum: 0)
            }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                state.renderCallCount += 1
                return RenderedCard(
                    frontHTML: "<p>render-\(state.renderCallCount)</p>",
                    backHTML: "<p>back-\(state.renderCallCount)</p>",
                    cardCSS: ""
                )
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            await waitForSettled(session)

            let originalNoteId = session.currentNote?.id
            #expect(state.renderCallCount == 1)
            #expect(session.frontHTML.contains("render-1"))

            // Simulate field edit
            state.noteFields = "new front\u{1f}new back"
            await session.refreshAfterEdit()

            #expect(session.currentNote?.id == originalNoteId, "queue does not advance")
            #expect(state.renderCallCount == 2, "renderCard called again on refresh")
            #expect(session.frontHTML.contains("render-2"), "frontHTML reflects re-render")
        }
    }

    // MARK: - Off-main advance (start/answer run their backend chain off the main actor)

    /// answer() answers the current card, re-fetches the queue, and advances to
    /// the next card — all off the main actor — then updates stats on main.
    @Test func answerAdvancesToNextCardAndUpdatesStats() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)
        let note1 = NoteRecord(id: NoteID(100), guid: "g1", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note2 = NoteRecord(id: NoteID(101), guid: "g2", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        final class Box: @unchecked Sendable { var answered = false }
        let box = Box()

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                // start() sees both cards; after answerReviewCard fires, only card2 remains.
                box.answered
                    ? QueuedCardsResult(cards: [card2], newCount: 1, learningCount: 0, reviewCount: 0)
                    : QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in box.answered = true }
            $0.notesService.getNote = { id in id == NoteID(100) ? note1 : note2 }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            await waitForSettled(s)
            #expect(s.currentNote == note1)

            s.answer(rating: .good)
            // answer() advances once the backend answer + queue refetch settle.
            await waitForSettled(s)

            #expect(s.sessionStats.reviewed == 1)
            #expect(s.sessionStats.correct == 1, "Good counts as correct")
            #expect(s.canUndo)
            #expect(s.currentNote == note2, "should advance to the second card")
            #expect(!s.isAdvancing, "isAdvancing clears once the answer settles")
        }
    }

    /// The session publishes live queue counts after start and after each
    /// answer. Stubbing the scheduler to return the engine's real transition
    /// (new−1, learn+1 on a first new-card answer) verifies the reviewer bar's
    /// data path stays live — not frozen on the session-start snapshot.
    @Test func liveCountsPublishedOnStartAndAfterAnswer() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)
        let note1 = NoteRecord(id: NoteID(100), guid: "g1", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note2 = NoteRecord(id: NoteID(101), guid: "g2", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        final class State: @unchecked Sendable { var answered = false }
        let state = State()
        let tracker = LiveReviewCounts()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                state.answered
                    ? QueuedCardsResult(cards: [card2], newCount: 1, learningCount: 1, reviewCount: 0)
                    : QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in state.answered = true }
            $0.notesService.getNote = { id in id == NoteID(100) ? note1 : note2 }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
            // The session's refineRemainingLearning overwrites the queue's
            // learn count with this search result, so the stub must mirror
            // the queue transition above — not the preview client's fixed 3.
            var stats = StatsClient.previewValue
            stats.learningDueToday = { _ in state.answered ? 1 : 0 }
            $0.statsClient = stats
            $0.liveReviewCounts = tracker
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            await waitForSettled(s)
            #expect(tracker.snapshot?.baseline == DeckCounts(newCount: 2, learnCount: 0, reviewCount: 0))
            #expect(tracker.snapshot?.live == DeckCounts(newCount: 2, learnCount: 0, reviewCount: 0))

            s.answer(rating: .good)
            await waitForSettled(s)
            #expect(tracker.snapshot?.baseline == DeckCounts(newCount: 2, learnCount: 0, reviewCount: 0),
                    "baseline stays frozen at session start")
            #expect(tracker.snapshot?.live == DeckCounts(newCount: 1, learnCount: 1, reviewCount: 0),
                    "live counts transition new->learning after an answer")
            #expect(s.remainingCounts == tracker.snapshot?.live,
                    "reviewer bar reads the same live counts the ring consumes")
        }
    }

    /// isAdvancing flips true synchronously inside start() (before the internal
    /// Task runs) and clears once the off-main transition settles.
    @Test func isAdvancingSetSynchronouslyThenClears() async throws {
        let card = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        try await withDependencies {
            $0.statsClient = .previewValue
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [card], newCount: 1, learningCount: 0, reviewCount: 0)
            }
            $0.notesService.getNote = { _ in
                NoteRecord(id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            #expect(s.isAdvancing, "start() sets isAdvancing synchronously before its Task runs")
            await waitForSettled(s)
            #expect(!s.isAdvancing, "isAdvancing clears after the transition settles")
            #expect(!s.isFinished, "a non-empty queue should not finish")
        }
    }

    // MARK: - Undo

    /// `undo()` re-fetches the queue after `cardClient.undoLast()` and
    /// advances to the card that was just answered — rolling the session stats
    /// back with it. This is the behaviour that was regressing in the field:
    /// the card must change, not just blink.
    @Test func undoReturnsToPreviousCardAndRollsBackStats() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)
        let note1 = NoteRecord(id: NoteID(100), guid: "g1", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note2 = NoteRecord(id: NoteID(101), guid: "g2", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        final class State: @unchecked Sendable {
            var answered = false
            var undone = false
        }
        let state = State()

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.decksService.setCurrentDeck = { _ in }
            // undo() verifies the target card returned to its pre-answer state
            // via cardClient.getCard, undoing repeatedly while it hasn't.
            $0.cardClient.undoLast = { state.undone = true }
            $0.cardClient.getCard = { _ in
                state.undone ? card1.card : answeredVariant(of: card1.card)
            }
            $0.schedulerService.getQueuedCards = { _ in
                if state.undone {
                    return QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
                }
                if state.answered {
                    return QueuedCardsResult(cards: [card2], newCount: 1, learningCount: 0, reviewCount: 0)
                }
                return QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in state.answered = true }
            $0.notesService.getNote = { id in id == NoteID(100) ? note1 : note2 }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            await waitForSettled(s)
            #expect(s.currentNote == note1)

            s.answer(rating: .good)
            await waitForSettled(s)
            #expect(s.currentNote == note2, "answer should advance to card2")
            #expect(s.sessionStats.reviewed == 1)
            #expect(s.sessionStats.correct == 1)
            #expect(s.canUndo)

            s.undo()
            await waitForSettled(s)

            #expect(s.currentNote == note1, "undo should return to card1")
            #expect(s.sessionStats.reviewed == 0, "undo should roll back reviewed count")
            #expect(s.sessionStats.correct == 0, "undo should roll back correct count")
            #expect(!s.canUndo, "no earlier answers remain to undo")
            #expect(!s.isAdvancing, "undo should clear isAdvancing")
        }
    }

    /// Continuous undo pops one answer at a time until the session start is
    /// reached again, restoring both the card and the per-answer stats.
    @Test func continuousUndoWalksBackToSessionStart() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)
        let card3 = QueuedReviewCard.preview(cardId: CardID(3), noteId: NoteID(102), ord: 0)
        let note1 = NoteRecord(id: NoteID(100), guid: "g1", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note2 = NoteRecord(id: NoteID(101), guid: "g2", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note3 = NoteRecord(id: NoteID(102), guid: "g3", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        final class State: @unchecked Sendable {
            var answers = 0
            var undos = 0
        }
        let state = State()

        let originals: [Int64: CardRecord] = [
            1: card1.card, 2: card2.card, 3: card3.card
        ]

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.decksService.setCurrentDeck = { _ in }
            $0.cardClient.undoLast = { state.undos += 1 }
            $0.cardClient.getCard = { id in
                // A card is back to its pre-answer state once the number of
                // backend undos exceeds the number of answers that followed it.
                let restored = id == CardID(3)
                    ? state.undos >= 2
                    : (id == CardID(2) ? state.undos >= 1 : state.undos >= 2)
                guard let original = originals[id.rawValue] else {
                    return card1.card
                }
                return restored ? original : answeredVariant(of: original)
            }
            $0.schedulerService.getQueuedCards = { _ in
                let all = [card1, card2, card3]
                let remaining = all.dropFirst(max(0, state.answers - state.undos))
                return QueuedCardsResult(
                    cards: Array(remaining),
                    newCount: remaining.count,
                    learningCount: 0,
                    reviewCount: 0
                )
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in state.answers += 1 }
            $0.notesService.getNote = { id in
                switch id {
                case NoteID(100): return note1
                case NoteID(101): return note2
                default: return note3
                }
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            await waitForSettled(s)
            #expect(s.currentNote == note1)

            s.answer(rating: .good)
            await waitForSettled(s)
            #expect(s.currentNote == note2)

            s.answer(rating: .again)
            await waitForSettled(s)
            #expect(s.currentNote == note3)
            #expect(s.sessionStats.reviewed == 2)
            #expect(s.sessionStats.correct == 1)
            #expect(s.canUndo)

            s.undo()
            await waitForSettled(s)
            #expect(s.currentNote == note2, "first undo returns to card2")
            #expect(s.sessionStats.reviewed == 1)
            #expect(s.sessionStats.correct == 1)
            #expect(s.canUndo, "still has an earlier answer to undo")

            s.undo()
            await waitForSettled(s)
            #expect(s.currentNote == note1, "second undo returns to card1")
            #expect(s.sessionStats.reviewed == 0)
            #expect(s.sessionStats.correct == 0)
            #expect(!s.canUndo, "session start reached")
        }
    }

    /// If the engine card never matches the queued snapshot, undo must not
    /// keep popping earlier answers. It redoes whatever it popped and
    /// leaves the session stack intact.
    @Test func undoFailureRestoresEngineStack() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)
        let note1 = NoteRecord(id: NoteID(100), guid: "g1", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note2 = NoteRecord(id: NoteID(101), guid: "g2", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        final class State: @unchecked Sendable {
            var answered = false
            var undos = 0
            var redos = 0
        }
        let state = State()

        try await withDependencies {
            $0.statsClient = .previewValue
            $0.decksService.setCurrentDeck = { _ in }
            $0.cardClient.undoLast = { state.undos += 1 }
            $0.cardClient.redoLast = { state.redos += 1 }
            $0.cardClient.getCard = { _ in answeredVariant(of: card1.card) }
            $0.schedulerService.getQueuedCards = { _ in
                if state.answered {
                    return QueuedCardsResult(cards: [card2], newCount: 1, learningCount: 0, reviewCount: 0)
                }
                return QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in state.answered = true }
            $0.notesService.getNote = { id in id == NoteID(100) ? note1 : note2 }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            await waitForSettled(s)
            s.answer(rating: .good)
            await waitForSettled(s)
            #expect(s.canUndo)

            s.undo()
            await waitForSettled(s)

            #expect(state.undos <= 3, "must not walk the whole engine stack")
            #expect(state.redos == state.undos, "failed undo must redo popped engine ops")
            #expect(s.canUndo, "session answer stack stays intact")
            #expect(s.sessionStats.reviewed == 1)
        }
    }
}

/// Polls until the session's off-main transition settles. start()/answer()/
/// undo() run their backend chain in an internal Task; a fixed sleep flakes
/// under load, while isAdvancing is the exact in-flight signal (cleared by
/// defer on every path, including failures).
@MainActor
private func waitForSettled(_ session: ReviewSession, timeout: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + timeout
    while session.isAdvancing, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A `CardRecord` in a clearly post-answer scheduling state — the "answer not
/// yet undone" variant returned by the `cardClient.getCard` stub in the undo
/// tests, which flips back to the pre-answer card once an undo has occurred.
private func answeredVariant(of card: CardRecord) -> CardRecord {
    CardRecord(
        id: card.id, nid: card.nid, did: card.did, ord: card.ord, mod: card.mod,
        usn: card.usn, type: 1, queue: 3, due: 60,
        ivl: card.ivl, factor: card.factor, reps: card.reps, lapses: card.lapses,
        left: card.left, odue: card.odue, odid: card.odid,
        flags: card.flags, data: card.data
    )
}
