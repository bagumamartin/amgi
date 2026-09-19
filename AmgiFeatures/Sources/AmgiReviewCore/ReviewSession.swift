import OSLog
public import SwiftUI
import AmgiAppCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
public import AmgiCardWeb
import AnkiClients
public import AnkiKit
import AnkiServices
import Dependencies
import Foundation
import Synchronization

/// How the current card is rendered (R11): parsed native content or the
/// sandboxed WebView. Resolved per card in `prepareCard`.
// Sendable is explicit here, not inferred: a public enum does not get the
// implicit Sendable conformance an internal one does.
public enum ResolvedRenderMode: Equatable, Sendable {
    case native(front: NativeCardContent, back: NativeCardContent)
    case html
}

private struct AnswerRecord {
    let queued: QueuedReviewCard
    var cardID: CardID { queued.card.id }
    let rating: Rating
    let timeSpent: Int
    let graduated: Bool
    let streakBefore: Int
    let extraEngineOpsAfter: Int
    let at: Date
}

private enum ReviewUndoError: Error {
    case cardNotRestored(CardID)
}

@Observable @MainActor
public final class ReviewSession {
    public let deckId: DeckID
    public var isAllDecksScope: Bool { deckId.rawValue == 0 }
    public private(set) var activeDeckName: String = ""

    @ObservationIgnored @Dependency(\.decksService) var decks
    @ObservationIgnored @Dependency(\.deckClient) var deckClient
    @ObservationIgnored @Dependency(\.cardClient) var cardClient
    @ObservationIgnored @Dependency(\.schedulerService) var scheduler
    @ObservationIgnored @Dependency(\.cardRenderingService) var cardRendering
    @ObservationIgnored @Dependency(\.collectionService) var collection
    @ObservationIgnored @Dependency(\.notesService) var notes
    @ObservationIgnored @Dependency(\.notetypesService) var notetypes
    @ObservationIgnored @Dependency(\.notetypesClient) var notetypesClient
    @ObservationIgnored @Dependency(\.statsClient) var statsClient
    @ObservationIgnored @Dependency(\.liveReviewCounts) var liveCounts

    /// Stable identity for this session's live-count publications, so the
    /// Study ring can re-anchor its collection snapshot once per session.
    private let liveSessionID = UUID()

    /// Active pool of deck IDs in this session. In all-decks mode, decks with
    /// ungraduated learning cards cooling down are retained so they can be
    /// revisited as other decks complete or as time elapses.
    private var activeDeckPool: [DeckID] = []
    private var currentDeckID: DeckID? = nil
    /// Snapshot counts for scopes that have not yet been selected. Combining
    /// these with the live current-queue counts keeps progress meaningful
    /// while a collection-wide session moves from deck to deck.
    private var remainingAllDeckCounts: [DeckID: DeckCounts] = [:]
    /// Original learn-ahead window in seconds before temporary review-ahead
    /// expansion. This stays outside Observation's generated mutable storage:
    /// `deinit` may run off the main actor and must restore the value safely.
    nonisolated private let originalLearnAheadSecs = Mutex<UInt32?>(nil)

    public private(set) var frontHTML: String = ""
    public private(set) var backHTML: String = ""
    public private(set) var cardCSS: String = ""
    public private(set) var showAnswer: Bool = false
    public private(set) var sessionStats: SessionStats = .init()
    public private(set) var remainingCounts: DeckCounts = .zero
    /// Category composition at session start — the live pulse's baseline.
    /// The Study ring subtracts it from its pre-session collection snapshot
    /// to repaint composition as cards are answered.
    public private(set) var sessionInitialCounts: DeckCounts = .zero
    /// Cards graduated today in this scope *before* this session began,
    /// fetched once at start. Combined with `graduatedCardIDs.count` to keep
    /// the daily completed count live without refetching per answer.
    public private(set) var dailyBaseGraduatedToday: Int = 0
    public private(set) var deckName: String = ""
    public private(set) var isFinished: Bool = false
    /// True when immediate queues are empty but cards are cooling down in
    /// learning/relearning steps for today. Prevents premature session completion.
    public private(set) var isWaitingForLearning: Bool = false
    public private(set) var waitingLearningCount: Int = 0
    public private(set) var canUndo: Bool = false
    public private(set) var nextIntervals: [Rating: String] = [:]
    public private(set) var replayRequestID: Int = 0       // plumbed; consumer is PR 1b
    public private(set) var stopAudioRequestID: Int = 0    // plumbed; consumer is PR 1b
    public private(set) var isAudioPlaying: Bool = false
    public private(set) var currentNote: NoteRecord?
    public private(set) var cardChromeColor: Color = .clear
    public private(set) var cardChromeIsDark: Bool = false
    public private(set) var resolvedMode: ResolvedRenderMode = .html
    public private(set) var resolvedByAuto: Bool = false
    public private(set) var templateName: String?
    /// Bumped on each rating tap, before the backend round-trip — the view's
    /// haptic trigger. `lastRating` can't serve: it lands after the round-trip
    /// and doesn't change when the same rating is tapped twice in a row.
    public private(set) var answerTapCount: Int = 0
    /// Rating of the most recent tap, paired with `answerTapCount` so the
    /// haptic can be firmer for `.again`.
    public private(set) var tappedRating: Rating = .good
    /// Bumped once per *successful* undo. Exists so the view can fire haptic
    /// feedback on the completion, which no other piece of state marks —
    /// `canUndo` already reads false when an undo isn't available at all.
    public private(set) var undoneCount: Int = 0
    /// The current card's most recent historical rating (nil = never
    /// reviewed); prefetched off-actor so the repeat shortcut is instant.
    public private(set) var currentCardLastRating: Rating? = nil
    /// Scheduling category of the current card, for the title-bar state dot.
    public private(set) var currentCardState: CardReviewState = .new
    /// Consecutive non-Again answers this session.
    public private(set) var correctStreak: Int = 0
    /// Bumped per graduating answer; the view fires the graduation haptic
    /// off it — kept separate from `answerTapCount` so only graduating
    /// answers (not any answer) trigger it.
    public private(set) var graduationPulse: Int = 0
    /// LIFO history of answers this session for undo and snapshot publishing.
    private var answerStack: [AnswerRecord] = []
    /// Card IDs graduated past today this session (next review ≥ tomorrow).
    /// Re-answers (Again, mid-step learning) never land here, so the daily
    /// bar completes exactly when today's cards are actually done.
    private var graduatedCardIDs: Set<CardID> = []
    /// Seconds until the next Anki day rollover, resolved once at start from
    /// the stats `rolloverHour`. Drives the graduation check (a "day" is not
    /// a fixed 24h).
    private var secondsUntilNextDayStart: UInt32 = 0
    /// Streak before the most recent answer, restored when that answer is
    /// undone.
    private var streakBeforeAnswer: Int = 0

    /// True while a card transition (start / answer / undo) has backend work
    /// in flight off the main actor. The view disables the answer + reveal
    /// buttons while set so a transition can't be re-entered mid-flight.
    public private(set) var isAdvancing: Bool = false
    /// Set when answering a card fails. The card stays at the head of the
    /// queue so the user can retry rather than silently losing the review.
    public var answerError: String?
    /// Set when `start()` fails. Distinct from `isFinished`, which means the
    /// queue genuinely ran dry — conflating them presented a backend failure
    /// as "Congratulations!", success haptic and all.
    public private(set) var startError: String?

    var reviewStartTime: ContinuousClock.Instant = .now
    var cardQueue: [QueuedReviewCard] = []
    /// Full notetypes fetched for template names; keyed by notetype id and
    /// kept for the session so each notetype is fetched once.
    var notetypeCache: [NotetypeID: Notetype] = [:]
    var currentQueuedCard: QueuedReviewCard?
    private var lastRating: Rating? = nil
    /// Single-slot speculative cache for the card *after* the current one,
    /// rendered during the seconds the user spends reading. On a hit the
    /// engine render drops out of the tap-to-next-card path entirely; on a
    /// miss (learning card resurfaced and changed the head) we fall through
    /// to the normal prepare.
    // ponytail: one slot, not a dict — the queue only ever advances by one.
    private var preparedNext: (id: CardID, card: PreparedCard)?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    // Typed-answer state
    var renderedFrontHTML: String = ""
    var renderedBackHTML: String = ""
    var typedAnswerState: TypedAnswerState?
    /// Bound to the native typed-answer field in ReviewView. Native (not an
    /// in-card HTML input) so keyboard traits fully apply — the predictive
    /// bar would otherwise offer the answer as a suggestion.
    public var typedAnswer: String = ""

    // MARK: - Computed

    public var requiresTypedAnswerInput: Bool {
        typedAnswerState?.expected.isEmpty == false && !showAnswer
    }

    public var currentCardOrdinal: UInt32 {
        UInt32(max(0, currentQueuedCard?.card.ord ?? 0))
    }

    public struct TemplateTarget: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let notetypeId: NotetypeID
        public let ordinal: Int

        public static func == (lhs: TemplateTarget, rhs: TemplateTarget) -> Bool {
            lhs.notetypeId == rhs.notetypeId && lhs.ordinal == rhs.ordinal
        }
    }

    public var currentTemplateTarget: TemplateTarget? {
        guard let card = currentQueuedCard?.card, let note = currentNote else { return nil }
        return TemplateTarget(notetypeId: note.mid, ordinal: Int(card.ord))
    }

    public var currentCardId: CardID? {
        currentQueuedCard?.card.id
    }

    /// Bottom 3 bits of the current card's flags field — the flag color
    /// index (0 = none, 1–7 = red/orange/green/blue/pink/cyan/purple).
    /// Mirrors the masking convention used by `cardClient.getCardFlags`.
    var currentFlag: UInt32 {
        UInt32(max(0, currentQueuedCard?.card.flags ?? 0)) & 0b111
    }

    /// Cards graduated past today in this scope (before + during this
    /// session) — i.e. whose next review is tomorrow or beyond.
    /// Re-answering a card (Again, mid-step learning) doesn't count.
    public var dailyCompletedToday: Int {
        dailyBaseGraduatedToday + graduatedCardIDs.count
    }

    /// Live cards still due today for the current scope.
    public var dailyRemainingToday: Int {
        max(remainingCounts.total, 0)
    }

    // MARK: - Init

    public init(deckId: DeckID) {
        self.deckId = deckId
    }

    deinit {
        // Session gone (user backed out / view torn down) — agents must not
        // see a stale "current card". Lock-based registry, safe off-actor.
        ReviewSessionContext.shared.clear()
        if let orig = originalLearnAheadSecs.withLock({ $0 }) {
            Task {
                @Dependency(\.schedulerService) var scheduler
                try? scheduler.setLearnAheadSecs(orig)
            }
        }
    }

    // MARK: - Agent context (get_review_context)

    /// Publishes live session state for the MCP bridge. Called on every
    /// card transition (start / answer / undo / finish / reveal) — one
    /// publish point in `advanceToNextCard` covers start/answer/undo, since
    /// those mutate their bookkeeping before advancing.
    private func publishContext() {
        let ratingName: (Rating) -> String = {
            switch $0 {
            case .again: return "again"
            case .hard: return "hard"
            case .good: return "good"
            case .easy: return "easy"
            }
        }
        let snapshot = ReviewSessionSnapshot(
            deckId: deckId.rawValue,
            deckName: deckName,
            isAllDecksScope: deckId.rawValue == 0,
            currentCardId: currentQueuedCard?.card.id.rawValue,
            currentNoteId: currentQueuedCard?.card.nid.rawValue,
            cardOrdinal: currentCardOrdinal,
            queueRemaining: max(cardQueue.count - (currentQueuedCard == nil ? 0 : 1), 0),
            isFinished: isFinished,
            isWaitingForLearning: isWaitingForLearning,
            isAnswerRevealed: showAnswer,
            reviewed: sessionStats.reviewed,
            correct: sessionStats.correct,
            streak: correctStreak,
            remainingNew: remainingCounts.newCount,
            remainingLearning: remainingCounts.learnCount,
            remainingReview: remainingCounts.reviewCount,
            answered: answerStack.map { record in
                .init(
                    cardId: record.cardID.rawValue,
                    rating: ratingName(record.rating),
                    atMs: Int64(record.at.timeIntervalSince1970 * 1000)
                )
            }
        )
        ReviewSessionContext.shared.publish(snapshot)
    }

    // MARK: - Public interface

    public func start() {
        guard !isAdvancing else { return }
        isAdvancing = true
        startError = nil
        // Resolve the Sendable service facades here, in the caller's
        // dependency scope, then hand them to the off-actor work.
        let decks = self.decks
        let deckClient = self.deckClient
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let statsClient = self.statsClient
        let deckId = self.deckId
        let allDeckScope = self.isAllDecksScope
        Task {
            defer { isAdvancing = false }
            do {
                var activeDeckIDs: [DeckID] = []
                var initialCounts: [DeckID: DeckCounts] = [:]
                if allDeckScope {
                    let tree = try await deckClient.fetchTree()
                    for node in tree {
                        if node.counts.total > 0 {
                            activeDeckIDs.append(node.id)
                            initialCounts[node.id] = node.counts
                        } else {
                            let learnToday = (try? await statsClient.learningDueToday(search: DeckSearch.term(node.fullName))) ?? 0
                            if learnToday > 0 {
                                activeDeckIDs.append(node.id)
                                initialCounts[node.id] = DeckCounts(newCount: 0, learnCount: learnToday, reviewCount: 0)
                            }
                        }
                    }
                } else {
                    activeDeckIDs = [deckId]
                    initialCounts = [:]
                }
                activeDeckPool = activeDeckIDs
                remainingAllDeckCounts = initialCounts

                guard !activeDeckIDs.isEmpty else {
                    let scopeSearch = allDeckScope ? "" : DeckSearch.term(deckName)
                    let learnDue = (try? await statsClient.learningDueToday(search: scopeSearch)) ?? 0
                    if learnDue > 0 {
                        isWaitingForLearning = true
                        waitingLearningCount = learnDue
                        isFinished = false
                        deckName = allDeckScope ? "All Decks" : ""
                        activeDeckName = deckName
                        remainingCounts = DeckCounts(newCount: 0, learnCount: learnDue, reviewCount: 0)
                        publishLiveCounts()
                        publishContext()
                    } else {
                        deckName = allDeckScope ? "All Decks" : ""
                        activeDeckName = ""
                        isFinished = true
                        isWaitingForLearning = false
                        publishContext()
                    }
                    return
                }

                var foundQueue: QueuedCardsResult? = nil
                var foundDeckID: DeckID? = nil
                var foundName: String = ""

                for candidateID in activeDeckIDs {
                    let res = try await Task.detached { () -> (QueuedCardsResult, String) in
                        try decks.setCurrentDeck(candidateID)
                        let name = (try? decks.getCurrentDeck().name) ?? ""
                        return (try scheduler.getQueuedCards(200), name)
                    }.value
                    if !res.0.cards.isEmpty {
                        foundQueue = res.0
                        foundDeckID = candidateID
                        foundName = res.1
                        break
                    } else if foundName.isEmpty {
                        foundName = res.1
                    }
                }

                if let queue = foundQueue, let pickedID = foundDeckID {
                    currentDeckID = pickedID
                    activeDeckName = foundName
                    deckName = allDeckScope ? "All Decks" : foundName
                    remainingAllDeckCounts.removeValue(forKey: pickedID)
                    cardQueue = queue.cards
                    remainingCounts = countsIncludingUnselectedDecks(queue)
                    await refineRemainingLearning(statsClient: statsClient)
                    sessionInitialCounts = remainingCounts
                    publishLiveCounts()
                    Log.review.info("Started with \(self.cardQueue.count) cards, counts: new=\(queue.newCount) learn=\(queue.learningCount) review=\(queue.reviewCount)")
                    await loadDailyProgress(statsClient: statsClient)
                    await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
                } else {
                    let scopeSearch = allDeckScope ? "" : DeckSearch.term(foundName)
                    let learnDue = (try? await statsClient.learningDueToday(search: scopeSearch)) ?? 0
                    if learnDue > 0 {
                        isWaitingForLearning = true
                        waitingLearningCount = learnDue
                        isFinished = false
                        deckName = allDeckScope ? "All Decks" : foundName
                        activeDeckName = deckName
                        remainingCounts = DeckCounts(newCount: 0, learnCount: learnDue, reviewCount: 0)
                        sessionInitialCounts = remainingCounts
                        publishLiveCounts()
                        publishContext()
                    } else {
                        deckName = allDeckScope ? "All Decks" : foundName
                        activeDeckName = ""
                        isFinished = true
                        isWaitingForLearning = false
                        remainingCounts = .zero
                        sessionInitialCounts = .zero
                        publishLiveCounts()
                        publishContext()
                    }
                }
            } catch {
                // NOT isFinished: that is the "queue ran dry" state and drives
                // the congratulations surface plus a success haptic. A start
                // failure gets its own state and a retry.
                Log.review.error("Start failed: \(error)")
                liveCounts.clear()
                startError = error.localizedDescription
            }
        }
    }

    /// Fetches today's graduated count and the rollover hour for the current
    /// scope. Best-effort: a failure never blocks the session.
    private func loadDailyProgress(statsClient: StatsClient) async {
        let search = isAllDecksScope ? "" : DeckSearch.term(deckName)

        do {
            let graphs = try await statsClient.fetchGraphs(search, 1)
            let graduated = try await statsClient.graduatedToday(search: search)
            dailyBaseGraduatedToday = graduated
            secondsUntilNextDayStart = DailyProgressCalculator.secondsUntilNextDayStart(
                rolloverHour: graphs.rolloverHour
            )
        } catch {
            dailyBaseGraduatedToday = 0
            // Conservative rollover fallback: with the boundary unknown,
            // sub-day intervals must NOT count as graduated (0 would make
            // every learning step `secs >= 0` → instant graduation).
            secondsUntilNextDayStart = 86_400
        }
    }

    /// Flips to the answer side immediately. For typed-answer cards the diff
    /// is computed off the main actor and substituted when it lands — the
    /// `compareAnswer` FFI call used to run inline here, blocking the main
    /// thread at the exact moment of the tap.
    public func revealAnswer() {
        backHTML = strippingTypedAnswerPlaceholders(from: renderedBackHTML)
        showAnswer = true
        publishContext()

        guard let state = typedAnswerState else { return }
        let typed = typedAnswer
        let rendered = renderedBackHTML
        let cardRendering = self.cardRendering
        let cardId = currentCardId
        Task {
            let html = await Task.detached {
                typedAnswerBackHTML(
                    state: state,
                    typedAnswer: typed,
                    renderedBackHTML: rendered,
                    cardRendering: cardRendering
                )
            }.value
            // The card can advance while the diff is in flight; don't paste a
            // stale answer over the new card.
            guard cardId == currentCardId, showAnswer else { return }
            backHTML = html
        }
    }

    public func answer(rating: Rating) {
        guard !isAdvancing, let queued = currentQueuedCard else { return }
        isAdvancing = true

        // ContinuousClock, not Date: a backwards wall-clock adjustment
        // (NTP correction, manual change) mid-review made this negative,
        // and UInt32(negative) traps. Clamped as well, since a card left
        // open for ~49.7 days would overflow.
        let elapsed = reviewStartTime.duration(to: .now)
        let elapsedMs = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        let timeSpent = UInt32(min(max(elapsedMs, 0), Int64(UInt32.max)))
        let cardId = queued.card.id
        let states = queued.states
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let statsClient = self.statsClient
        let decks = self.decks
        let allDeckScope = self.isAllDecksScope

        answerTapCount += 1
        tappedRating = rating
        streakBeforeAnswer = correctStreak

        // The interval brackets the whole tap-to-next-card wait, not the
        // synchronous prologue above: the scheduler round-trip and the
        // advance are what the user actually waits on.
        Task {
            defer { isAdvancing = false }
            await AppSignpost.measure("AnswerCard") {
                do {
                    var queue = try await Task.detached {
                        try scheduler.answerReviewCard(cardId, rating, timeSpent, states)
                        return try scheduler.getQueuedCards(200)
                    }.value

                    // An all-decks session keeps Anki's scheduler on one real
                    // deck at a time. Once that deck's queue is empty, cycle
                    // through other decks in the active pool instead of ending
                    // the aggregate session or discarding cooling decks.
                    var extraEngineOpsAfter = 0
                    if allDeckScope, queue.cards.isEmpty {
                        let currentTerm = DeckSearch.term(activeDeckName)
                        let currentRemainingLearn = (try? await statsClient.learningDueToday(search: currentTerm)) ?? 0
                        if currentRemainingLearn == 0, let curID = currentDeckID {
                            activeDeckPool.removeAll { $0 == curID }
                            remainingAllDeckCounts.removeValue(forKey: curID)
                        }

                        var switched = false
                        for candidateID in activeDeckPool where candidateID != currentDeckID {
                            extraEngineOpsAfter += 1
                            let candidateResult = try await Task.detached { () -> (QueuedCardsResult, String) in
                                try decks.setCurrentDeck(candidateID)
                                let name = (try? decks.getCurrentDeck().name) ?? ""
                                return (try scheduler.getQueuedCards(200), name)
                            }.value
                            if !candidateResult.0.cards.isEmpty {
                                queue = candidateResult.0
                                currentDeckID = candidateID
                                activeDeckName = candidateResult.1
                                remainingAllDeckCounts.removeValue(forKey: candidateID)
                                switched = true
                                break
                            }
                        }

                        if !switched, let curID = currentDeckID {
                            let retryQueue = try await Task.detached { () -> QueuedCardsResult in
                                try decks.setCurrentDeck(curID)
                                return try scheduler.getQueuedCards(200)
                            }.value
                            if !retryQueue.cards.isEmpty {
                                queue = retryQueue
                            }
                        }
                    }

                    answerError = nil
                    sessionStats.reviewed += 1
                    if rating != .again { sessionStats.correct += 1 }
                    sessionStats.totalTimeMs += Int(timeSpent)
                    // Graduated = the chosen rating schedules the next review
                    // on a future Anki day (after the next rollover) — not
                    // simply "24h out". Same precomputed state the backend
                    // applies.
                    let graduated = queued.nextScheduled[rating]
                        .map { DailyProgressCalculator.isGraduated(interval: $0, secondsUntilNextDayStart: secondsUntilNextDayStart) } ?? false
                    if graduated {
                        graduatedCardIDs.insert(queued.card.id)
                        graduationPulse += 1
                    }
                    answerStack.append(AnswerRecord(
                        queued: queued,
                        rating: rating,
                        timeSpent: Int(timeSpent),
                        graduated: graduated,
                        streakBefore: streakBeforeAnswer,
                        extraEngineOpsAfter: extraEngineOpsAfter,
                        at: .now
                    ))
                    lastRating = rating
                    correctStreak = rating != .again ? correctStreak + 1 : 0
                    canUndo = true

                    cardQueue = queue.cards
                    remainingCounts = countsIncludingUnselectedDecks(queue)
                    await refineRemainingLearning(statsClient: statsClient)
                    publishLiveCounts()
                    await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
                } catch {
                    // Do NOT drop the card. Silently removing it from the queue
                    // and advancing meant the review was never recorded, the
                    // card was skipped for the session, remainingCounts drifted
                    // permanently from the backend's, and the user saw an
                    // entirely normal advance.
                    Log.review.error("Answer failed: \(error)")
                    answerError = error.localizedDescription
                }
            }
        }
    }

    /// Repeat shortcut: rate the card the way IT was rated last time
    /// (from its revlog history). New cards with no review history default
    /// to Again. No-op unless the answer is showing and no transition is
    /// in flight.
    public func answerWithLastRating() {
        guard showAnswer, !isAdvancing else { return }
        answer(rating: currentCardLastRating ?? .again)
    }

    public func undo() {
        guard canUndo, !isAdvancing, let record = answerStack.last else { return }
        isAdvancing = true

        let cardClient = self.cardClient
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let statsClient = self.statsClient
        let decks = self.decks
        let allDeckScope = self.isAllDecksScope
        let target = record.queued
        let originalCard = target.card
        let undoneCardID = target.card.id

        Task {
            defer { isAdvancing = false }
            do {
                // One user undo must revert exactly this answer. Deck switches
                // after the answer leave `SetCurrentDeck` entries on top of
                // the engine stack; pop those, then the AnswerCard.
                var current = try await cardClient.getCard(undoneCardID)
                var undoCount = 0
                let undoBudget = record.extraEngineOpsAfter + 1 + 2
                do {
                    while !cardIsRestored(current, to: originalCard) {
                        guard undoCount < undoBudget else {
                            throw ReviewUndoError.cardNotRestored(undoneCardID)
                        }
                        try await cardClient.undoLast()
                        undoCount += 1
                        current = try await cardClient.getCard(undoneCardID)
                    }
                } catch {
                    for _ in 0..<undoCount {
                        try? await cardClient.redoLast()
                    }
                    throw error
                }

                // Re-fetch queue — Anki places the undone card at the front
                let (queue, currentName) = try await Task.detached { () -> (QueuedCardsResult, String) in
                    let q = try scheduler.getQueuedCards(200)
                    let name = (try? decks.getCurrentDeck().name) ?? ""
                    return (q, name)
                }.value

                answerStack.removeLast()
                canUndo = !answerStack.isEmpty
                undoneCount += 1

                // Roll back session stats only if the operation we just
                // undid was actually an answer.
                sessionStats.reviewed = max(0, sessionStats.reviewed - 1)
                if record.rating != .again {
                    sessionStats.correct = max(0, sessionStats.correct - 1)
                }
                sessionStats.totalTimeMs = max(0, sessionStats.totalTimeMs - record.timeSpent)
                if record.graduated {
                    graduatedCardIDs.remove(undoneCardID)
                }
                lastRating = nil
                correctStreak = record.streakBefore

                // Put the undone card back at the front of the display queue.
                cardQueue = [target] + queue.cards.filter { $0.card.id != undoneCardID }
                isWaitingForLearning = false
                isFinished = false
                if allDeckScope, !currentName.isEmpty {
                    activeDeckName = currentName
                }
                remainingCounts = countsIncludingUnselectedDecks(queue)
                await refineRemainingLearning(statsClient: statsClient)
                publishLiveCounts()
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
            } catch {
                Log.review.error("Undo failed: \(error)")
            }
        }
    }

    public func updateAudioPlaying(_ playing: Bool) {
        isAudioPlaying = playing
    }

#if canImport(UIKit)
    public func updateCardChrome(color: UIColor, isDark: Bool) {
        cardChromeColor = Color(uiColor: color)
        cardChromeIsDark = isDark
    }
#elseif canImport(AppKit)
    public func updateCardChrome(color: NSColor, isDark: Bool) {
        cardChromeColor = Color(nsColor: color)
        cardChromeIsDark = isDark
    }
#endif

    /// Publishes the session's live queue counts so the Study ring can
    /// repaint its new/learning/review composition as cards are answered.
    private func publishLiveCounts() {
        liveCounts.publish(
            sessionID: liveSessionID,
            baseline: sessionInitialCounts,
            live: remainingCounts
        )
    }

    /// Current scheduler counts cover the selected deck; the virtual
    /// all-decks scope adds the untouched top-level decks that are still
    /// waiting to be selected.
    private func countsIncludingUnselectedDecks(_ queue: QueuedCardsResult) -> DeckCounts {
        var counts = DeckCounts(
            newCount: queue.newCount,
            learnCount: queue.learningCount,
            reviewCount: queue.reviewCount
        )
        for pending in remainingAllDeckCounts.values {
            counts.newCount += pending.newCount
            counts.learnCount += pending.learnCount
            counts.reviewCount += pending.reviewCount
        }
        return counts
    }

    /// Replaces the queue-derived learn count with the TRUE number of
    /// learning/relearning cards still due before the next rollover. The
    /// scheduler's counts only include intraday learning within its
    /// learn-ahead window (~20 min) — a card answered Again with a longer
    /// step would vanish from `remaining`, making the progress bar jump
    /// without any graduation. The search is rollover-aware (`prop:due<=0`
    /// compares against the next day start) and excludes buried/suspended.
    /// Best-effort: on failure the queue-derived count stands.
    private func refineRemainingLearning(statsClient: StatsClient) async {
        let search = isAllDecksScope ? "" : DeckSearch.term(deckName)
        if let learning = try? await statsClient.learningDueToday(search: search) {
            remainingCounts.learnCount = learning
        }
    }

    public func bumpReplayRequest() {
        replayRequestID += 1
    }

    public func bumpStopAudioRequest() {
        stopAudioRequestID += 1
    }

    /// Temporarily expands the intraday learn-ahead window to pull cooling
    /// learning cards into the queue immediately, allowing the user to finish
    /// today's remaining cards without waiting.
    public func reviewAhead() {
        guard !isAdvancing else { return }
        isAdvancing = true
        let scheduler = self.scheduler
        let decks = self.decks
        let statsClient = self.statsClient
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering

        Task {
            defer { isAdvancing = false }
            do {
                if originalLearnAheadSecs.withLock({ $0 }) == nil {
                    let original = try? scheduler.getLearnAheadSecs()
                    originalLearnAheadSecs.withLock { $0 = original }
                }
                try scheduler.setLearnAheadSecs(86_400)

                var foundQueue: QueuedCardsResult? = nil
                for deckID in activeDeckPool {
                    let res = try await Task.detached { () -> (QueuedCardsResult, String) in
                        try decks.setCurrentDeck(deckID)
                        let name = (try? decks.getCurrentDeck().name) ?? ""
                        return (try scheduler.getQueuedCards(200), name)
                    }.value
                    if !res.0.cards.isEmpty {
                        foundQueue = res.0
                        currentDeckID = deckID
                        activeDeckName = res.1
                        break
                    }
                }

                if let queue = foundQueue, !queue.cards.isEmpty {
                    cardQueue = queue.cards
                    isWaitingForLearning = false
                    waitingLearningCount = 0
                    remainingCounts = countsIncludingUnselectedDecks(queue)
                    await refineRemainingLearning(statsClient: statsClient)
                    publishLiveCounts()
                    await advanceToNextCard(
                        notes: notes,
                        notetypes: notetypes,
                        notetypesClient: notetypesClient,
                        cardRendering: cardRendering,
                        statsClient: statsClient
                    )
                } else {
                    isWaitingForLearning = false
                    isFinished = true
                    publishContext()
                }
            } catch {
                Log.review.error("reviewAhead failed: \(error)")
            }
        }
    }

    /// Re-evaluates queues to see if any cooling learning cards have matured.
    public func checkWaitingQueue() {
        guard isWaitingForLearning, !isAdvancing else { return }
        isAdvancing = true
        let scheduler = self.scheduler
        let decks = self.decks
        let statsClient = self.statsClient
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering

        Task {
            defer { isAdvancing = false }
            do {
                var foundQueue: QueuedCardsResult? = nil
                for deckID in activeDeckPool {
                    let res = try await Task.detached { () -> (QueuedCardsResult, String) in
                        try decks.setCurrentDeck(deckID)
                        let name = (try? decks.getCurrentDeck().name) ?? ""
                        return (try scheduler.getQueuedCards(200), name)
                    }.value
                    if !res.0.cards.isEmpty {
                        foundQueue = res.0
                        currentDeckID = deckID
                        activeDeckName = res.1
                        break
                    }
                }

                if let queue = foundQueue, !queue.cards.isEmpty {
                    cardQueue = queue.cards
                    isWaitingForLearning = false
                    waitingLearningCount = 0
                    remainingCounts = countsIncludingUnselectedDecks(queue)
                    await refineRemainingLearning(statsClient: statsClient)
                    publishLiveCounts()
                    await advanceToNextCard(
                        notes: notes,
                        notetypes: notetypes,
                        notetypesClient: notetypesClient,
                        cardRendering: cardRendering,
                        statsClient: statsClient
                    )
                } else {
                    let scopeSearch = isAllDecksScope ? "" : DeckSearch.term(deckName)
                    let learnDue = (try? await statsClient.learningDueToday(search: scopeSearch)) ?? 0
                    if learnDue == 0 {
                        isWaitingForLearning = false
                        isFinished = true
                        publishContext()
                    } else {
                        waitingLearningCount = learnDue
                    }
                }
            } catch {
                Log.review.error("checkWaitingQueue failed: \(error)")
            }
        }
    }

    /// Explicitly finishes the session early even if learning cards are cooling down.
    public func finishEarly() {
        isWaitingForLearning = false
        isFinished = true
        publishContext()
    }
}

extension ReviewSession {

    /// Re-renders the current card after the note or template was edited.
    /// The whole engine round-trip runs off the main actor — it used to call
    /// `getNote` and `renderCard` inline, blocking the main thread while the
    /// edit sheet was dismissing.
    public func refreshAfterEdit() async {
        guard let queued = currentQueuedCard else { return }
        invalidatePrefetch()   // the edit may have changed a shared notetype

        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let statsClient = self.statsClient
        let cache = notetypeCache
        let prepared = await Task.detached {
            await prepareCard(
                for: queued,
                notes: notes,
                notetypes: notetypes,
                cardRendering: cardRendering,
                notetypesClient: notetypesClient,
                notetypeCache: cache,
                statsClient: statsClient
            )
        }.value

        guard currentQueuedCard?.card.id == queued.card.id else { return }

        currentNote = prepared.note
        if let notetype = prepared.notetype {
            notetypeCache[notetype.id] = notetype
        }
        renderedFrontHTML = prepared.renderedFrontHTML
        renderedBackHTML = prepared.renderedBackHTML
        cardCSS = prepared.cardCSS
        typedAnswerState = prepared.typedAnswerState
        templateName = prepared.templateName
        frontHTML = prepared.frontHTML
        backHTML = strippingTypedAnswerPlaceholders(from: prepared.renderedBackHTML)
        reresolveCurrentCard()

        if showAnswer, let state = prepared.typedAnswerState {
            // Re-substitute the back placeholder with the diff; the typed text
            // survives the sheet round-trip in `typedAnswer`.
            let typed = typedAnswer
            let rendered = prepared.renderedBackHTML
            let html = await Task.detached {
                typedAnswerBackHTML(
                    state: state,
                    typedAnswer: typed,
                    renderedBackHTML: rendered,
                    cardRendering: cardRendering
                )
            }.value
            guard currentQueuedCard?.card.id == queued.card.id, showAnswer else { return }
            backHTML = html
        }
    }

    /// Re-runs render-mode resolution for the current card against the
    /// latest engine preference / overrides (RenderModeSheet writes).
    /// Cheap: reuses the already-rendered HTML.
    public func reresolveCurrentCard() {
        // The prefetched card was prepared against the *old* preferences.
        invalidatePrefetch()
        guard let queued = currentQueuedCard else { return }
        let prefs = currentRenderEnginePreferences(mid: currentNote?.mid, ord: Int(queued.card.ord))
        let resolution = resolveRenderMode(
            renderedFront: renderedFrontHTML,
            renderedBack: renderedBackHTML,
            css: cardCSS,
            override: prefs.override,
            global: prefs.global
        )
        resolvedMode = resolution.mode
        resolvedByAuto = resolution.byAuto
    }
}

private extension ReviewSession {
    // MARK: - Private: card advancement

    /// Advances to the next queued card. Pops the queue on the main actor,
    /// then renders the card off the main actor via `Task.detached` and
    /// assigns the resulting state back here. The scheduler/queue mutation
    /// already happened in the caller; this only prepares display state.
    func advanceToNextCard(
        notes: NotesService,
        notetypes: NotetypesService,
        notetypesClient: NotetypesClient,
        cardRendering: CardRenderingService,
        statsClient: StatsClient
    ) async {
        guard let next = cardQueue.first else {
            let scopeSearch = isAllDecksScope ? "" : DeckSearch.term(deckName)
            let learnDue = (try? await statsClient.learningDueToday(search: scopeSearch)) ?? 0
            if learnDue > 0 {
                isWaitingForLearning = true
                waitingLearningCount = learnDue
                isFinished = false
                remainingCounts = DeckCounts(newCount: 0, learnCount: learnDue, reviewCount: 0)
                publishLiveCounts()
            } else {
                isFinished = true
                isWaitingForLearning = false
                remainingCounts = .zero
                publishLiveCounts()
            }
            currentQueuedCard = nil
            currentNote = nil
            invalidatePrefetch()
            publishContext()
            return
        }

        isWaitingForLearning = false
        waitingLearningCount = 0

        let prepared: PreparedCard
        if let hit = preparedNext, hit.id == next.card.id {
            prepared = hit.card
        } else {
            let cache = notetypeCache
            prepared = await Task.detached {
                await prepareCard(
                    for: next,
                    notes: notes,
                    notetypes: notetypes,
                    cardRendering: cardRendering,
                    notetypesClient: notetypesClient,
                    notetypeCache: cache,
                    statsClient: statsClient
                )
            }.value
        }
        preparedNext = nil

        currentQueuedCard = next
        currentNote = prepared.note
        if let notetype = prepared.notetype {
            notetypeCache[notetype.id] = notetype
        }
        resolvedMode = prepared.resolvedMode
        resolvedByAuto = prepared.resolvedByAuto
        templateName = prepared.templateName
        renderedFrontHTML = prepared.renderedFrontHTML
        renderedBackHTML = prepared.renderedBackHTML
        cardCSS = prepared.cardCSS
        typedAnswerState = prepared.typedAnswerState
        typedAnswer = ""
        frontHTML = prepared.frontHTML
        backHTML = prepared.renderedBackHTML  // back substitution happens at reveal
        nextIntervals = next.nextIntervals
        currentCardLastRating = prepared.lastRating
        currentCardState = CardReviewState(cardType: next.card.type)
        // Preserve chrome continuity for HTML→HTML: the progress bar and
        // button regions share `cardChromeColor` with the card canvas via
        // `ReviewContent.background`. Clearing unconditionally caused a flash
        // to `palette.background`/`Color.clear` between HTML cards, breaking
        // the illusion. Only clear for native cards (which never report a
        // chrome colour) so a stale HTML colour doesn't pin the palette.
        if case .native = prepared.resolvedMode {
            cardChromeColor = .clear
            cardChromeIsDark = false
        }
        showAnswer = false
        reviewStartTime = .now
        stopAudioRequestID += 1
        publishContext()

        // Spend the user's reading time rendering the card after this one.
        prefetchFollowingCard(
            notes: notes,
            notetypes: notetypes,
            notetypesClient: notetypesClient,
            cardRendering: cardRendering,
            statsClient: statsClient
        )
    }

    // MARK: - Prefetch

    /// Renders the card after the current one while the user reads, into a
    /// single-slot cache. Speculative: the queue is re-fetched on every
    /// answer, so a learning card can resurface and change the head — a miss
    /// just costs the work we would have done anyway.
    func prefetchFollowingCard(
        notes: NotesService,
        notetypes: NotetypesService,
        notetypesClient: NotetypesClient,
        cardRendering: CardRenderingService,
        statsClient: StatsClient
    ) {
        prefetchTask?.cancel()
        guard cardQueue.count > 1 else {
            preparedNext = nil
            return
        }
        let next = cardQueue[1]
        guard preparedNext?.id != next.card.id else { return }
        preparedNext = nil

        let cache = notetypeCache
        prefetchTask = Task { [weak self] in
            let prepared = await Task.detached {
                await prepareCard(
                    for: next,
                    notes: notes,
                    notetypes: notetypes,
                    cardRendering: cardRendering,
                    notetypesClient: notetypesClient,
                    notetypeCache: cache,
                    statsClient: statsClient
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.preparedNext = (id: next.card.id, card: prepared)
        }
    }

    func invalidatePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        preparedNext = nil
    }

}

/// True when `card` has been reverted to its scheduling state at queue time
/// (`original`). Excludes volatile fields the answer/undo cycle updates for
/// bookkeeping (`mod`, `usn`). `undo()` uses this to detect whether the last
/// backend undo actually reverted this card — an auto deck-switch in an
/// all-decks session can leave a `SetCurrentDeck` entry on top of an answer.
private func cardIsRestored(_ card: CardRecord, to original: CardRecord) -> Bool {
    card.did == original.did
        && card.type == original.type
        && card.queue == original.queue
        && card.due == original.due
        && card.ivl == original.ivl
        && card.left == original.left
        && card.odue == original.odue
        && card.odid == original.odid
        && card.factor == original.factor
        && card.reps == original.reps
}

#if DEBUG
extension ReviewSession {
    /// Builds a session with canned display state for SwiftUI previews.
    /// Never calls `start()`, so it touches no backend — `ReviewContent`
    /// previews render the card or finished surface deterministically.
    /// Lives in this file so it can set the `private(set)` display state.
    /// Public because `ReviewContent`'s previews live in the app target.
    public static func preview(
        showAnswer: Bool = false,
        isFinished: Bool = false,
        isWaitingForLearning: Bool = false,
        waitingLearningCount: Int = 0,
        front: String = "<div class=\"card\">猫</div>",
        back: String = "<div class=\"card\">猫<hr>cat — a small domesticated feline</div>",
        reviewed: Int = 7,
        counts: DeckCounts = DeckCounts(newCount: 5, learnCount: 2, reviewCount: 13)
    ) -> ReviewSession {
        let session = ReviewSession(deckId: DeckID(1))
        session.frontHTML = front
        session.backHTML = back
        session.cardCSS = """
        .card { font-family: -apple-system; font-size: 30px; text-align: center; padding: 24px; }
        hr { margin: 20px 0; border: none; border-top: 1px solid #ccc; }
        """
        session.showAnswer = showAnswer
        session.isFinished = isFinished
        session.isWaitingForLearning = isWaitingForLearning
        session.waitingLearningCount = waitingLearningCount
        session.sessionStats = SessionStats(reviewed: reviewed, correct: 6, totalTimeMs: 42_000)
        session.remainingCounts = counts
        session.deckName = "한국어 · Vocab Typing"
        session.nextIntervals = [.again: "<1m", .hard: "8m", .good: "1d", .easy: "4d"]
        session.canUndo = reviewed > 0
        session.templateName = "Card 1"
        return session
    }
}
#endif
