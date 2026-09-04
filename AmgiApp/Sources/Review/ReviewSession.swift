import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AmgiCardWeb
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation

/// How the current card is rendered (R11): parsed native content or the
/// sandboxed WebView. Resolved per card in `prepareCard`.
enum ResolvedRenderMode: Equatable {
    case native(front: NativeCardContent, back: NativeCardContent)
    case html
}

/// One answered card's rollback state, stored LIFO by `ReviewSession` so
/// `undo()` can walk back to the first card of the session.
private struct AnswerRecord {
    /// The card as it was *before* being answered — queue position, scheduling
    /// states, and next-interval strings. `undo()` restores exactly this card
    /// to the front of the display queue.
    let queued: QueuedReviewCard
    var cardID: CardID { queued.card.id }
    let rating: Rating
    let timeSpent: Int
    let graduated: Bool
    let streakBefore: Int
    /// Engine undo entries recorded *after* this answer (all-decks
    /// `SetCurrentDeck` hops). Session undo pops these first, then the
    /// AnswerCard — one user undo == one answered card.
    let extraEngineOpsAfter: Int
    /// Wall-clock moment of the answer — feeds the agent-facing
    /// `ReviewSessionSnapshot.answered` timeline.
    let at: Date = .now
}

/// Fired when the backend undo stack cannot rewind the target card back to
/// its pre-answer state. The session leaves the answer record intact so the
/// user can retry.
private enum ReviewUndoError: Error {
    case cardNotRestored(CardID)
}

@Observable @MainActor
final class ReviewSession {
    let deckId: DeckID

    @ObservationIgnored @Dependency(\.decksService) var decks
    @ObservationIgnored @Dependency(\.deckClient) var deckClient
    @ObservationIgnored @Dependency(\.schedulerService) var scheduler
    @ObservationIgnored @Dependency(\.cardRenderingService) var cardRendering
    @ObservationIgnored @Dependency(\.collectionService) var collection
    @ObservationIgnored @Dependency(\.notesService) var notes
    @ObservationIgnored @Dependency(\.notetypesService) var notetypes
    @ObservationIgnored @Dependency(\.notetypesClient) var notetypesClient
    @ObservationIgnored @Dependency(\.statsClient) var statsClient
    @ObservationIgnored @Dependency(\.cardClient) var cardClient
    @ObservationIgnored @Dependency(\.liveReviewCounts) var liveCounts

    /// Stable identity for this session's live-count publications, so the
    /// Study ring can re-anchor its collection snapshot once per session.
    private let liveSessionID = UUID()

    private(set) var frontHTML: String = ""
    private(set) var backHTML: String = ""
    private(set) var cardCSS: String = ""
    private(set) var showAnswer: Bool = false
    private(set) var sessionStats: SessionStats = .init()
    private(set) var remainingCounts: DeckCounts = .zero
    /// Category composition at the start of the session. The review chrome
    /// uses this stable snapshot to paint its segmented progress fill; live
    /// counts still drive the remaining-card label.
    private(set) var sessionInitialCounts: DeckCounts = .zero
    /// Denominator for session progress (n/N label + bar). Frozen at
    /// session start and only allowed to grow when learning cards re-enter
    /// the queue — never shrinks, so the bar doesn't jump backward.
    private(set) var sessionProgressTotal: Int = 0
    /// Cards that graduated today in this scope *before* this session began,
    /// fetched once at session start. Combined with `graduatedCardIDs.count`
    /// to keep the daily completed count live without refetching per answer.
    private(set) var dailyBaseGraduatedToday: Int = 0
    private(set) var deckName: String = ""
    private(set) var isFinished: Bool = false
    private(set) var canUndo: Bool = false
    private(set) var nextIntervals: [Rating: String] = [:]
    private(set) var replayRequestID: Int = 0       // plumbed; consumer is PR 1b
    private(set) var stopAudioRequestID: Int = 0    // plumbed; consumer is PR 1b
    private(set) var isAudioPlaying: Bool = false
    private(set) var currentNote: NoteRecord?
    private(set) var cardChromeColor: Color = .clear
    private(set) var cardChromeIsDark: Bool = false
    private(set) var resolvedMode: ResolvedRenderMode = .html
    private(set) var resolvedByAuto: Bool = false
    private(set) var templateName: String?

    /// True while a card transition (start / answer / undo) has backend work
    /// in flight off the main actor. The view disables the answer + reveal
    /// buttons while set so a transition can't be re-entered mid-flight.
    private(set) var isAdvancing: Bool = false

    private var reviewStartTime: Date = .now
    private var cardQueue: [QueuedReviewCard] = []
    /// Full notetypes fetched for template names; keyed by notetype id and
    /// kept for the session so each notetype is fetched once.
    private var notetypeCache: [NotetypeID: Notetype] = [:]
    private var currentQueuedCard: QueuedReviewCard?
    private(set) var lastRating: Rating? = nil
    /// The rating the CURRENT card received on its most recent review (from
    /// the revlog), prefetched during card preparation. `nil` for cards never
    /// reviewed — the space-bar "repeat last rating" shortcut maps that to
    /// `.again`.
    private(set) var currentCardLastRating: Rating? = nil
    /// Which category the current card belongs to (new / learning / review /
    /// relearning), derived from the card's `type` field at advance time and
    /// surfaced as the state dot in the review title bar.
    private(set) var currentCardState: CardReviewState = .new
    /// Increments once per answered card so the view can fire a rating-tuned
    /// haptic as the next card snaps in.
    private(set) var answerPulse = 0
    /// Increments once per successful undo so the view can flash a brief
    /// "Undo" toast as the previous card snaps back in.
    private(set) var undoToastPulse = 0
    /// Card IDs that have graduated past today's scope this session — answered
    /// with a rating whose next review is ≥ 1 day out ("tomorrow or beyond").
    /// The daily progress bar counts only these, so re-answers (Again, mid-step
    /// learning) don't inflate progress and the bar completes exactly when
    /// today's cards are actually done.
    private var graduatedCardIDs: Set<CardID> = []
    /// Seconds from now until the next Anki day rollover, resolved once at
    /// session start from the stats `rolloverHour`. Drives the day-boundary
    /// graduation check (a "day" is not a fixed 24h).
    private var secondsUntilNextDayStart: UInt32 = 0
    /// Increments each time an answer graduates a card. The view observes this
    /// to fire a graduation haptic — kept separate from `answerPulse` so only
    /// graduating answers (not any answer) trigger it.
    private(set) var graduationPulse = 0
    /// LIFO history of answers this session. `undo()` pops the most recent
    /// record so a reverted answer restores exactly the state it changed —
    /// stats, graduation, and streak — enabling continuous undo back to the
    /// first card of the session.
    private var answerStack: [AnswerRecord] = []
    /// Consecutive non-"Again" answers in this session.
    private(set) var correctStreak = 0
    /// `DeckID(0)` is Amgi's virtual “All Decks” review scope. Anki's
    /// scheduler itself has one current deck, so this holds the remaining
    /// active top-level deck IDs that will be selected as each queue empties.
    private var remainingAllDeckIDs: [DeckID] = []
    /// Snapshot counts for scopes that have not yet been selected. Combining
    /// these with the live current-queue counts keeps progress meaningful
    /// while a collection-wide session moves from deck to deck.
    private var remainingAllDeckCounts: [DeckID: DeckCounts] = [:]

    // Typed-answer state
    private var renderedFrontHTML: String = ""
    private var renderedBackHTML: String = ""
    private var typedAnswerState: TypedAnswerState?
    /// Bound to the native typed-answer field in ReviewView. Native (not an
    /// in-card HTML input) so keyboard traits fully apply — the predictive
    /// bar would otherwise offer the answer as a suggestion.
    var typedAnswer: String = ""

    // MARK: - Computed

    var requiresTypedAnswerInput: Bool {
        typedAnswerState?.expected.isEmpty == false && !showAnswer
    }

    var currentCardOrdinal: UInt32 {
        UInt32(currentQueuedCard?.card.ord ?? 0)
    }

    struct TemplateTarget: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let notetypeId: NotetypeID
        public let ordinal: Int

        public static func == (lhs: TemplateTarget, rhs: TemplateTarget) -> Bool {
            lhs.notetypeId == rhs.notetypeId && lhs.ordinal == rhs.ordinal
        }
    }

    var currentTemplateTarget: TemplateTarget? {
        guard let card = currentQueuedCard?.card, let note = currentNote else { return nil }
        return TemplateTarget(notetypeId: note.mid, ordinal: Int(card.ord))
    }

    var currentCardId: CardID? {
        currentQueuedCard?.card.id
    }

    /// Bottom 3 bits of the current card's flags field — the flag color
    /// index (0 = none, 1–7 = red/orange/green/blue/pink/cyan/purple).
    /// Mirrors the masking convention used by `cardClient.getCardFlags`.
    var currentFlag: UInt32 {
        UInt32(currentQueuedCard?.card.flags ?? 0) & 0b111
    }

    /// Cards that have graduated past today's scope today in this scope
    /// (before + during this session) — i.e. whose next review is tomorrow or
    /// beyond. Re-answering a card (Again, mid-step learning) doesn't count.
    var dailyCompletedToday: Int {
        dailyBaseGraduatedToday + graduatedCardIDs.count
    }

    /// Live cards still due today for the current scope.
    var dailyRemainingToday: Int {
        max(remainingCounts.total, 0)
    }

    // MARK: - Init

    init(deckId: DeckID) {
        self.deckId = deckId
    }

    deinit {
        // Session gone (user backed out / view torn down) — agents must not
        // see a stale "current card". Lock-based registry, safe off-actor.
        ReviewSessionContext.shared.clear()
    }

    // MARK: - Agent context (get_review_context)

    /// Publishes live session state for the MCP bridge. Called on every
    /// card transition (start / answer / undo / finish) — one publish
    /// point in `advanceToNextCard` covers all of them, since answer and
    /// undo mutate their bookkeeping before advancing.
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

    func start() {
        guard !isAdvancing else { return }
        isAdvancing = true
        // Resolve the Sendable service facades here, in the caller's
        // dependency scope, then hand them to the off-actor work.
        let decks = self.decks
        let deckClient = self.deckClient
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let deckId = self.deckId
        Task {
            defer { isAdvancing = false }
            do {
                let allDeckScope = deckId.rawValue == 0
                let activeDeckIDs: [DeckID]
                if allDeckScope {
                    let tree = try await deckClient.fetchTree()
                    let activeDecks = tree.filter { $0.counts.total > 0 }
                    activeDeckIDs = activeDecks.map(\.id)
                    remainingAllDeckCounts = Dictionary(
                        uniqueKeysWithValues: activeDecks.map { ($0.id, $0.counts) }
                    )
                } else {
                    activeDeckIDs = [deckId]
                    remainingAllDeckCounts = [:]
                }
                guard let initialDeckID = activeDeckIDs.first else {
                    deckName = allDeckScope ? "All Decks" : ""
                    isFinished = true
                    return
                }
                var pendingDeckIDs = Array(activeDeckIDs.dropFirst())
                let firstDeckToLoad = initialDeckID
                remainingAllDeckCounts.removeValue(forKey: firstDeckToLoad)
                var result = try await Task.detached { () -> (QueuedCardsResult, String) in
                    try decks.setCurrentDeck(firstDeckToLoad)
                    let name = (try? decks.getCurrentDeck().name) ?? ""
                    return (try scheduler.getQueuedCards(200), name)
                }.value

                // Counts can become stale between Library/widget snapshot
                // generation and launch. Skip an empty selected deck rather
                // than treating it as the end of an all-decks session.
                while allDeckScope, result.0.cards.isEmpty, let nextDeckID = pendingDeckIDs.first {
                    pendingDeckIDs.removeFirst()
                    let deckToLoad = nextDeckID
                    remainingAllDeckCounts.removeValue(forKey: deckToLoad)
                    result = try await Task.detached { () -> (QueuedCardsResult, String) in
                        try decks.setCurrentDeck(deckToLoad)
                        let name = (try? decks.getCurrentDeck().name) ?? ""
                        return (try scheduler.getQueuedCards(200), name)
                    }.value
                }

                let (queue, name) = result
                cardQueue = queue.cards
                remainingAllDeckIDs = pendingDeckIDs
                deckName = allDeckScope ? "All Decks" : name
                remainingCounts = countsIncludingUnselectedDecks(queue)
                await refineRemainingLearning()
                sessionInitialCounts = remainingCounts
                updateSessionProgressTotal()
                publishLiveCounts()
                print("[ReviewSession] Started with \(cardQueue.count) cards, counts: new=\(queue.newCount) learn=\(queue.learningCount) review=\(queue.reviewCount)")
                await loadDailyProgress()
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
            } catch {
                print("[ReviewSession] Start failed: \(error)")
                liveCounts.clear()
                isFinished = true
            }
        }
    }

    /// Fetches today's graduated count and the rollover hour for the current
    /// scope. Best-effort: a failure never blocks the session.
    private func loadDailyProgress() async {
        let allDeckScope = deckId.rawValue == 0
        let search = allDeckScope ? "" : DeckUsageRanking.deckSearch(fullName: deckName)

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

    func revealAnswer() {
        print("[ReviewSession] revealAnswer entered, showAnswer=\(showAnswer)")
        if let state = typedAnswerState {
            backHTML = makeTypedAnswerBackHTML(state: state, typedAnswer: typedAnswer)
        } else {
            // Also consumed by the watch surface, so this runs even when
            // `resolvedMode` is native.
            backHTML = strippingTypedAnswerPlaceholders(from: renderedBackHTML)
        }
        showAnswer = true
        publishContext()
    }

    func answer(rating: Rating) {
        guard !isAdvancing, let queued = currentQueuedCard else { return }
        isAdvancing = true

        let timeSpent = UInt32(Date.now.timeIntervalSince(reviewStartTime) * 1000)
        let cardId = queued.card.id
        let states = queued.states
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let decks = self.decks

        let newStreak = rating != .again ? correctStreak + 1 : 0

        Task {
            defer {
                isAdvancing = false
            }
            do {
                var queue = try await Task.detached {
                    try scheduler.answerReviewCard(cardId, rating, timeSpent, states)
                    return try scheduler.getQueuedCards(200)
                }.value

                // An all-decks session keeps Anki's scheduler on one real
                // deck at a time. Once that deck's queue is empty, advance
                // to the next active top-level deck instead of ending the
                // aggregate session.
                var extraEngineOpsAfter = 0
                while queue.cards.isEmpty, let nextDeckID = remainingAllDeckIDs.first {
                    remainingAllDeckIDs.removeFirst()
                    remainingAllDeckCounts.removeValue(forKey: nextDeckID)
                    extraEngineOpsAfter += 1
                    queue = try await Task.detached {
                        try decks.setCurrentDeck(nextDeckID)
                        return try scheduler.getQueuedCards(200)
                    }.value
                }

                sessionStats.reviewed += 1
                if rating != .again { sessionStats.correct += 1 }
                sessionStats.totalTimeMs += Int(timeSpent)
                print("[ReviewSession] Answer: answered=\(cardId) rating=\(rating) queue=\(queue.cards.count)")
                // Graduated = the chosen rating schedules the next review on
                // a future Anki day (after the next rollover) — not simply
                // "24h out". Same precomputed state the backend applies.
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
                    streakBefore: correctStreak,
                    extraEngineOpsAfter: extraEngineOpsAfter
                ))
                lastRating = rating
                answerPulse += 1
                correctStreak = newStreak
                canUndo = true

                cardQueue = queue.cards
                remainingCounts = countsIncludingUnselectedDecks(queue)
                await refineRemainingLearning()
                updateSessionProgressTotal()
                publishLiveCounts()
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
            } catch {
                print("[ReviewSession] Answer failed: \(String(describing: error))")
                if !cardQueue.isEmpty { cardQueue.removeFirst() }
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
            }
        }
    }

    /// Space-bar repeat: rate the card the way IT was rated last time
    /// (from its revlog history). New cards with no review history default
    /// to Again. No-op unless the answer is showing and no transition is
    /// in flight.
    func answerWithLastRating() {
        guard showAnswer, !isAdvancing else { return }
        answer(rating: currentCardLastRating ?? .again)
    }

    func undo() {        guard canUndo, !isAdvancing, let record = answerStack.last else {
            print("[ReviewSession] Undo skipped: canUndo=\(canUndo) isAdvancing=\(isAdvancing) answerStack=\(answerStack.count)")
            return
        }
        isAdvancing = true

        let cardClient = self.cardClient
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let currentCardID = currentQueuedCard?.card.id
        let target = record.queued
        let originalCard = target.card
        let undoneCardID = target.card.id

        Task {
            defer { isAdvancing = false }
            do {
                print("[ReviewSession] Undo: currentCard=\(String(describing: currentCardID)) target=\(undoneCardID) stack=\(answerStack.count)")
                // One user undo must revert exactly this answer. Deck switches
                // after the answer leave `SetCurrentDeck` entries on top of
                // the engine stack; a flag/bury from the overflow menu can
                // too. Pop those, then the AnswerCard. Cap is small on
                // purpose: the previous loop (up to 20) ate earlier answers
                // when `cardIsRestored` missed, which is why ⌘Z died after
                // 1–4 steps. If we still haven't restored the card, redo
                // everything we popped so the engine stack stays intact.
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
                // Re-fetch queue — the undone card is re-inserted at the front.
                let queue = try await Task.detached {
                    try scheduler.getQueuedCards(200)
                }.value

                print("[ReviewSession] Undo: queue=\(queue.cards.count) first=\(String(describing: queue.cards.first?.card.id))")

                // Drop the record only after the backend undo succeeds, then
                // leave undo enabled while earlier answers remain.
                answerStack.removeLast()
                canUndo = !answerStack.isEmpty

                // Roll back session stats for this specific answer.
                sessionStats.reviewed -= 1
                if record.rating != .again {
                    sessionStats.correct -= 1
                }
                sessionStats.totalTimeMs = max(0, sessionStats.totalTimeMs - record.timeSpent)
                if record.graduated {
                    graduatedCardIDs.remove(undoneCardID)
                }
                lastRating = nil
                correctStreak = record.streakBefore

                // Put the undone card back at the front of the display queue.
                // The backend already restores it, but the refetch can re-sort
                // or omit it (e.g. across a deck switch), so make the restore
                // deterministic from the pre-answer capture.
                cardQueue = [target] + queue.cards.filter { $0.card.id != undoneCardID }
                remainingCounts = countsIncludingUnselectedDecks(queue)
                await refineRemainingLearning()
                updateSessionProgressTotal()
                publishLiveCounts()
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering, statsClient: statsClient)
                undoToastPulse += 1
            } catch {
                print("[ReviewSession] Undo failed: \(String(describing: error))")
            }
        }
    }

    func updateAudioPlaying(_ playing: Bool) {
        isAudioPlaying = playing
    }

#if canImport(UIKit)
    func updateCardChrome(color: UIColor, isDark: Bool) {
        cardChromeColor = Color(uiColor: color)
        cardChromeIsDark = isDark
    }
#elseif canImport(AppKit)
    func updateCardChrome(color: NSColor, isDark: Bool) {
        cardChromeColor = Color(nsColor: color)
        cardChromeIsDark = isDark
    }
#endif

    func bumpReplayRequest() {
        replayRequestID += 1
    }

    func bumpStopAudioRequest() {
        stopAudioRequestID += 1
    }

    func refreshAfterEdit() async {
        guard let queued = currentQueuedCard else { return }

        do {
            currentNote = try notes.getNote(queued.card.nid)
        } catch {
            print("[ReviewSession] refreshAfterEdit getNote failed: \(error)")
        }

        do {
            let rendered = try cardRendering.renderCard(queued.card.id)
            renderedFrontHTML = rendered.frontHTML
            renderedBackHTML = rendered.backHTML
            cardCSS = rendered.cardCSS

            typedAnswerState = resolveTypedAnswerState(
                for: queued,
                frontHTML: rendered.frontHTML,
                notes: notes,
                notetypes: notetypes,
                cardRendering: cardRendering
            )
            frontHTML = strippingTypedAnswerPlaceholders(from: renderedFrontHTML)

            if showAnswer, let state = typedAnswerState {
                // Re-substitute back placeholder with the diff; the typed text
                // survives the sheet round-trip in `typedAnswer`.
                backHTML = makeTypedAnswerBackHTML(state: state, typedAnswer: typedAnswer)
            } else {
                backHTML = renderedBackHTML
            }
        } catch {
            print("[ReviewSession] refreshAfterEdit render failed: \(error)")
        }
        reresolveCurrentCard()
    }

    /// Re-runs render-mode resolution for the current card against the
    /// latest engine preference / overrides (RenderModeSheet writes).
    /// Cheap: reuses the already-rendered HTML.
    func reresolveCurrentCard() {
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
    /// Publishes the session's live queue counts so the Study ring can
    /// repaint its new/learning/review composition as cards are answered.
    func publishLiveCounts() {
        liveCounts.publish(
            sessionID: liveSessionID,
            baseline: sessionInitialCounts,
            live: remainingCounts
        )
    }

    /// Current scheduler counts cover the selected deck; the virtual
    /// all-decks scope adds the untouched top-level decks that are still
    /// waiting to be selected.
    func countsIncludingUnselectedDecks(_ queue: QueuedCardsResult) -> DeckCounts {
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
    private func refineRemainingLearning() async {
        let allDeckScope = deckId.rawValue == 0
        let search = allDeckScope ? "" : DeckUsageRanking.deckSearch(fullName: deckName)
        if let learning = try? await statsClient.learningDueToday(search: search) {
            remainingCounts.learnCount = learning
        }
    }

    /// Keeps the session denominator stable: set once at start, then only
    /// grow when re-learning inflates the remaining queue.
    func updateSessionProgressTotal() {
        let current = max(sessionStats.reviewed + remainingCounts.total, 1)
        sessionProgressTotal = max(sessionProgressTotal, current)
    }

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
            isFinished = true
            currentQueuedCard = nil
            currentNote = nil
            publishContext()
            return
        }

        let cache = notetypeCache
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

        currentQueuedCard = next
        currentNote = prepared.note
        isFinished = false
        publishContext()
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
    }

    // MARK: - Typed-answer HTML generation (main-actor side)

    func makeTypedAnswerBackHTML(state: TypedAnswerState, typedAnswer: String) -> String {
        guard renderedBackHTML.contains(state.placeholder) else {
            return renderedBackHTML
        }
        if state.expected.isEmpty {
            return renderedBackHTML.replacingOccurrences(of: state.placeholder, with: "")
        }
        do {
            let diff = try cardRendering.compareAnswer(state.expected, typedAnswer, state.combining)
            let wrapped = "<div style=\"font-family: '\(state.fontName)'; font-size: \(state.fontSize)px\">\(diff)</div>"
            return renderedBackHTML.replacingOccurrences(of: state.placeholder, with: wrapped)
        } catch {
            print("[ReviewSession] compareAnswer failed: \(error)")
            return renderedBackHTML.replacingOccurrences(of: state.placeholder, with: "")
        }
    }

}

// MARK: - Off-main card preparation

/// The scheduling category of the card under review, for the title-bar state
/// dot. Anki's `card.type` is 0 new / 1 learning / 2 review / 3 relearning,
/// but the reviewer's progress model is 3-way — new / learning / review —
/// where relearning is a sub-state of learning (it is counted in
/// `QueuedCards.learningCount` / `DeckCounts.learnCount` and painted with the
/// same orange in `DailyProgressBar`). Mapping `type == 3` → `.learning`
/// keeps the title-bar dot's hue aligned with the progress bar's segment for
/// the current card. `.relearning` is retained as an alias for
/// compatibility but is not produced.
enum CardReviewState: Sendable {
    case new
    case learning
    case review
    case relearning

    init(cardType: Int16) {
        switch cardType {
        case 1, 3: self = .learning
        case 2: self = .review
        default: self = .new
        }
    }

    /// Convenience for queue-based callers; `type == 3` is learning for the
    /// same reason as above.
    init(cardQueue: Int16) {
        switch cardQueue {
        case 0: self = .new
        case 1, 3, 4: self = .learning // Learn / DayLearn / PreviewRepeat → orange
        case 2: self = .review
        default: self = .new
        }
    }
}

//
// These run inside `Task.detached`, so they are file-scope `nonisolated`
// functions that take the Sendable service facades explicitly rather than
// reaching through `self`. They produce a `Sendable PreparedCard` that
// `advanceToNextCard` assigns to `@Observable` state on the main actor.

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
        && card.lapses == original.lapses
}

/// Immutable, off-actor render result for one queued card.
private struct PreparedCard: Sendable {
    let note: NoteRecord?
    let renderedFrontHTML: String
    let renderedBackHTML: String
    let cardCSS: String
    let typedAnswerState: TypedAnswerState?
    let frontHTML: String
    let resolvedMode: ResolvedRenderMode
    let resolvedByAuto: Bool
    let templateName: String?
    /// Freshly fetched notetype for the session cache; nil on cache hit
    /// or fetch failure.
    let notetype: Notetype?
    /// The card's most recent historical rating (nil = never reviewed);
    /// prefetched off-actor so the space-bar repeat shortcut is instant.
    let lastRating: Rating?
}

/// Applies the R11 resolution order — template override → global preference
/// → complexity auto-detect — to one rendered card. `alwaysNative` still
/// yields `.html` when the card fails the simplicity check, so native
/// rendering is never lossy.
func resolveRenderMode(
    renderedFront: String,
    renderedBack: String,
    css: String,
    override: CardRenderEngine?,
    global: CardRenderEngine
) -> (mode: ResolvedRenderMode, byAuto: Bool) {
    let effective = override ?? global
    let simple = CardComplexity.isSimple(
        renderedFront: renderedFront,
        renderedBack: renderedBack,
        css: css
    )
    let wantNative = effective != .alwaysHTML && simple
    let mode: ResolvedRenderMode = wantNative
        ? .native(front: .parse(html: renderedFront), back: .parse(html: renderedBack))
        : .html
    return (mode, effective == .auto)
}

/// Reads the R11 engine preference + per-template override for one card.
/// UserDefaults is thread-safe, so this is callable from the off-actor
/// prepare path as well as main-actor re-resolution.
func currentRenderEnginePreferences(mid: NotetypeID?, ord: Int) -> (global: CardRenderEngine, override: CardRenderEngine?) {
    let defaults = UserDefaults.standard
    let global = defaults.string(forKey: ReviewPreferences.Keys.cardRenderEngine)
        .flatMap(CardRenderEngine.init(rawValue:)) ?? .auto
    let overridesRaw = defaults.string(forKey: ReviewPreferences.Keys.templateRenderOverrides) ?? "{}"
    let override = mid.flatMap { TemplateRenderOverrides.engine(for: $0, ord: ord, in: overridesRaw) }
    return (global, override)
}

private struct TypedAnswerPlaceholder {
    let rawToken: String
    let fieldName: String
    let combining: Bool
    let clozeOrdinal: UInt32?
}

private func prepareCard(
    for queued: QueuedReviewCard,
    notes: NotesService,
    notetypes: NotetypesService,
    cardRendering: CardRenderingService,
    notetypesClient: NotetypesClient,
    notetypeCache: [NotetypeID: Notetype],
    statsClient: StatsClient
) async -> PreparedCard {
    let note: NoteRecord?
    do {
        note = try notes.getNote(queued.card.nid)
    } catch {
        print("[ReviewSession] getNote failed: \(error)")
        note = nil
    }

    // Prefetch the card's most recent rating (revlog) so the space-bar
    // "repeat last rating" shortcut is instant at reveal time. Best-effort:
    // a failure just means no hint (falls back to Again).
    let lastRating = try? await statsClient.lastRating(queued.card.id.rawValue)

    // Template name comes from the full notetype (cached per session);
    // fetch failure only costs the chip-row label.
    var fetchedNotetype: Notetype?
    var templateName: String?
    if let mid = note?.mid {
        let notetype: Notetype?
        if let cached = notetypeCache[mid] {
            notetype = cached
        } else {
            fetchedNotetype = try? await notetypesClient.get(mid)
            notetype = fetchedNotetype
        }
        let ord = Int(queued.card.ord)
        if let notetype, notetype.templates.indices.contains(ord) {
            templateName = notetype.templates[ord].name
        }
    }

    do {
        let rendered = try cardRendering.renderCard(queued.card.id)
        let typedState = resolveTypedAnswerState(
            for: queued,
            frontHTML: rendered.frontHTML,
            notes: notes,
            notetypes: notetypes,
            cardRendering: cardRendering
        )
        let prefs = currentRenderEnginePreferences(mid: note?.mid, ord: Int(queued.card.ord))
        let resolution = resolveRenderMode(
            renderedFront: rendered.frontHTML,
            renderedBack: rendered.backHTML,
            css: rendered.cardCSS,
            override: prefs.override,
            global: prefs.global
        )
        if case .html = resolution.mode {
            let issue = CardComplexity.complexityIssue(
                renderedFront: rendered.frontHTML,
                renderedBack: rendered.backHTML,
                css: rendered.cardCSS
            ) ?? "engine preference (global: \(prefs.global.rawValue), override: \(prefs.override?.rawValue ?? "none"))"
            print("[ReviewSession] card \(queued.card.id.rawValue) → HTML: \(issue); front=\(String(rendered.frontHTML.prefix(200)))")
        }
        return PreparedCard(
            note: note,
            renderedFrontHTML: rendered.frontHTML,
            renderedBackHTML: rendered.backHTML,
            cardCSS: rendered.cardCSS,
            typedAnswerState: typedState,
            frontHTML: strippingTypedAnswerPlaceholders(from: rendered.frontHTML),
            resolvedMode: resolution.mode,
            resolvedByAuto: resolution.byAuto,
            templateName: templateName,
            notetype: fetchedNotetype,
            lastRating: lastRating
        )
    } catch {
        print("[ReviewSession] Render failed for card \(queued.card.id): \(error)")
        return PreparedCard(
            note: note,
            renderedFrontHTML: "<p>Error rendering card</p>",
            renderedBackHTML: "<p>Error rendering card</p>",
            cardCSS: "",
            typedAnswerState: nil,
            frontHTML: "<p>Error rendering card</p>",
            resolvedMode: .html,
            resolvedByAuto: false,
            templateName: templateName,
            notetype: fetchedNotetype,
            lastRating: lastRating
        )
    }
}

// MARK: - Typed-answer state resolution

private func resolveTypedAnswerState(
    for queued: QueuedReviewCard,
    frontHTML: String,
    notes: NotesService,
    notetypes: NotetypesService,
    cardRendering: CardRenderingService
) -> TypedAnswerState? {
    guard let placeholder = firstTypedAnswerPlaceholder(
        in: frontHTML,
        cardOrdinal: UInt32(queued.card.ord)
    ) else {
        return nil
    }

    do {
        let noteRecord = try notes.getNote(queued.card.nid)

        // Fetch per-field font/size config via service (keeps backend access inside AnkiServices).
        let fields = try notetypes.getNotetypeFields(noteRecord.mid)

        guard let field = fields.first(where: { $0.name == placeholder.fieldName }) else {
            // Field name not found — typed answer with empty expected
            return TypedAnswerState(
                placeholder: placeholder.rawToken,
                expected: "",
                combining: placeholder.combining,
                fontName: "-apple-system",
                fontSize: 18
            )
        }

        let fieldValues = noteRecord.flds.components(separatedBy: "\u{1f}")
        guard fieldValues.indices.contains(field.ordinal) else {
            return nil
        }

        var expected = fieldValues[field.ordinal]

        // Cloze typed-answer: extract the specific cloze ordinal's text
        if let clozeOrdinal = placeholder.clozeOrdinal {
            expected = try cardRendering.extractClozeForTyping(expected, clozeOrdinal)
        }

        return TypedAnswerState(
            placeholder: placeholder.rawToken,
            expected: expected,
            combining: placeholder.combining,
            fontName: field.fontName,
            fontSize: field.fontSize
        )
    } catch {
        print("[ReviewSession] Typed answer resolution failed for card \(queued.card.id): \(error)")
        return nil
    }
}

// MARK: - Placeholder parsing

private func firstTypedAnswerPlaceholder(in html: String, cardOrdinal: UInt32) -> TypedAnswerPlaceholder? {
    guard let regex = try? NSRegularExpression(pattern: #"\[\[type:(.+?)\]\]"#) else {
        return nil
    }
    let nsRange = NSRange(html.startIndex..., in: html)
    guard let match = regex.firstMatch(in: html, range: nsRange),
          let rawRange = Range(match.range(at: 0), in: html),
          let specRange = Range(match.range(at: 1), in: html)
    else {
        return nil
    }

    var spec = String(html[specRange])
    var combining = true
    var clozeOrdinal: UInt32?

    if spec.hasPrefix("cloze:") {
        spec.removeFirst("cloze:".count)
        clozeOrdinal = cardOrdinal + 1
    }
    if spec.hasPrefix("nc:") {
        spec.removeFirst("nc:".count)
        combining = false
    }

    guard !spec.isEmpty else { return nil }

    return TypedAnswerPlaceholder(
        rawToken: String(html[rawRange]),
        fieldName: spec,
        combining: combining,
        clozeOrdinal: clozeOrdinal
    )
}

private func strippingTypedAnswerPlaceholders(from html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"\[\[type:.+?\]\]"#) else {
        return html
    }
    let range = NSRange(html.startIndex..., in: html)
    return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
}

#if DEBUG
extension ReviewSession {
    /// Builds a session with canned display state for SwiftUI previews.
    /// Never calls `start()`, so it touches no backend — `ReviewContent`
    /// previews render the card or finished surface deterministically.
    /// Lives in this file so it can set the `private(set)` display state.
    static func preview(
        showAnswer: Bool = false,
        isFinished: Bool = false,
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
        session.sessionStats = SessionStats(reviewed: reviewed, correct: 6, totalTimeMs: 42_000)
        session.remainingCounts = counts
        session.sessionInitialCounts = counts
        session.sessionProgressTotal = max(reviewed + counts.total, 1)
        session.dailyBaseGraduatedToday = reviewed
        session.deckName = "한국어 · Vocab Typing"
        session.nextIntervals = [.again: "<1m", .hard: "8m", .good: "1d", .easy: "4d"]
        session.canUndo = reviewed > 0
        session.templateName = "Card 1"
        return session
    }
}
#endif
