import OSLog
public import SwiftUI
import AmgiAppCore
#if canImport(UIKit)
import UIKit
#endif
public import AmgiCardWeb
import AnkiClients
public import AnkiKit
import AnkiServices
import Dependencies
import Foundation

/// How the current card is rendered (R11): parsed native content or the
/// sandboxed WebView. Resolved per card in `prepareCard`.
// Sendable is explicit here, not inferred: a public enum does not get the
// implicit Sendable conformance an internal one does.
public enum ResolvedRenderMode: Equatable, Sendable {
    case native(front: NativeCardContent, back: NativeCardContent)
    case html
}

@Observable @MainActor
public final class ReviewSession {
    public let deckId: DeckID

    @ObservationIgnored @Dependency(\.decksService) var decks
    @ObservationIgnored @Dependency(\.schedulerService) var scheduler
    @ObservationIgnored @Dependency(\.cardRenderingService) var cardRendering
    @ObservationIgnored @Dependency(\.collectionService) var collection
    @ObservationIgnored @Dependency(\.notesService) var notes
    @ObservationIgnored @Dependency(\.notetypesService) var notetypes
    @ObservationIgnored @Dependency(\.notetypesClient) var notetypesClient

    public private(set) var frontHTML: String = ""
    public private(set) var backHTML: String = ""
    public private(set) var cardCSS: String = ""
    public private(set) var showAnswer: Bool = false
    public private(set) var sessionStats: SessionStats = .init()
    public private(set) var remainingCounts: DeckCounts = .zero
    public private(set) var deckName: String = ""
    public private(set) var isFinished: Bool = false
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

    // MARK: - Init

    public init(deckId: DeckID) {
        self.deckId = deckId
    }

    // MARK: - Public interface

    public func start() {
        guard !isAdvancing else { return }
        isAdvancing = true
        startError = nil
        // Resolve the Sendable service facades here, in the caller's
        // dependency scope, then hand them to the off-actor work.
        let decks = self.decks
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let deckId = self.deckId
        Task {
            defer { isAdvancing = false }
            do {
                let (queue, name) = try await Task.detached { () -> (QueuedCardsResult, String) in
                    try decks.setCurrentDeck(deckId)
                    let name = (try? decks.getCurrentDeck().name) ?? ""
                    return (try scheduler.getQueuedCards(200), name)
                }.value
                cardQueue = queue.cards
                deckName = name
                remainingCounts = DeckCounts(
                    newCount: queue.newCount,
                    learnCount: queue.learningCount,
                    reviewCount: queue.reviewCount
                )
                Log.review.info("Started with \(self.cardQueue.count) cards, counts: new=\(queue.newCount) learn=\(queue.learningCount) review=\(queue.reviewCount)")
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
            } catch {
                // NOT isFinished: that is the "queue ran dry" state and drives
                // the congratulations surface plus a success haptic. A start
                // failure gets its own state and a retry.
                Log.review.error("Start failed: \(error)")
                startError = error.localizedDescription
            }
        }
    }

    public func revealAnswer() {
        if let state = typedAnswerState {
            backHTML = makeTypedAnswerBackHTML(state: state, typedAnswer: typedAnswer)
        } else {
            backHTML = strippingTypedAnswerPlaceholders(from: renderedBackHTML)
        }
        showAnswer = true
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

        answerTapCount += 1
        tappedRating = rating

        Task {
            defer { isAdvancing = false }
            do {
                let queue = try await Task.detached {
                    try scheduler.answerReviewCard(cardId, rating, timeSpent, states)
                    return try scheduler.getQueuedCards(200)
                }.value

                answerError = nil
                sessionStats.reviewed += 1
                if rating != .again { sessionStats.correct += 1 }
                sessionStats.totalTimeMs += Int(timeSpent)
                lastRating = rating
                canUndo = true

                cardQueue = queue.cards
                remainingCounts = DeckCounts(
                    newCount: queue.newCount,
                    learnCount: queue.learningCount,
                    reviewCount: queue.reviewCount
                )
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
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

    public func undo() {
        guard canUndo, !isAdvancing else { return }
        isAdvancing = true

        let collection = self.collection
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering

        Task {
            defer { isAdvancing = false }
            do {
                let queue = try await Task.detached {
                    try collection.undoLast()
                    // Re-fetch queue — Anki places the undone card at the front
                    return try scheduler.getQueuedCards(200)
                }.value

                canUndo = false
                undoneCount += 1
                // Roll back session stats only if the operation we just
                // undid was actually an answer. undoLast() undoes the last
                // *collection* operation, and a note edit is reachable from
                // this screen (refreshAfterEdit) — decrementing regardless
                // drove the counters below their true value, and negative.
                if let last = lastRating {
                    sessionStats.reviewed = max(0, sessionStats.reviewed - 1)
                    if last != .again {
                        sessionStats.correct = max(0, sessionStats.correct - 1)
                    }
                }
                lastRating = nil

                cardQueue = queue.cards
                remainingCounts = DeckCounts(
                    newCount: queue.newCount,
                    learnCount: queue.learningCount,
                    reviewCount: queue.reviewCount
                )
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
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
#endif

    public func bumpReplayRequest() {
        replayRequestID += 1
    }

    public func bumpStopAudioRequest() {
        stopAudioRequestID += 1
    }

    public func refreshAfterEdit() async {
        guard let queued = currentQueuedCard else { return }

        do {
            currentNote = try notes.getNote(queued.card.nid)
        } catch {
            Log.review.error("refreshAfterEdit getNote failed: \(error)")
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
            Log.review.error("refreshAfterEdit render failed: \(error)")
        }
        reresolveCurrentCard()
    }

    /// Re-runs render-mode resolution for the current card against the
    /// latest engine preference / overrides (RenderModeSheet writes).
    /// Cheap: reuses the already-rendered HTML.
    public func reresolveCurrentCard() {
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
        cardRendering: CardRenderingService
    ) async {
        guard let next = cardQueue.first else {
            isFinished = true
            currentQueuedCard = nil
            currentNote = nil
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
                notetypeCache: cache
            )
        }.value

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
            Log.review.error("compareAnswer failed: \(error)")
            return renderedBackHTML.replacingOccurrences(of: state.placeholder, with: "")
        }
    }

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
        session.deckName = "한국어 · Vocab Typing"
        session.nextIntervals = [.again: "<1m", .hard: "8m", .good: "1d", .easy: "4d"]
        session.canUndo = reviewed > 0
        session.templateName = "Card 1"
        return session
    }
}
#endif
