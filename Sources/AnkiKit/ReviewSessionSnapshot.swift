import Foundation

/// Live review-session state published by Amgi.app's `ReviewSession` and
/// served to the `amgi-mcp` helper over the IPC bridge
/// (`MCPBridge.sessionStateMethod`). Lets an AI agent see WHICH card is
/// on the user's screen, the deck scope, and what was answered today —
/// context the engine alone cannot know.
///
/// Lifecycle: exists only while the app is open AND a review session is
/// (or was recently) active. The helper asks over `mcp.sock`; a dead
/// socket means the app is closed, a `nil` snapshot means no session.
/// Never persisted to disk — it is live UI state by definition.
public struct ReviewSessionSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    /// Epoch milliseconds when the snapshot was published.
    public var updatedAtMs: Int64
    /// Review scope. `0` is Amgi's virtual "All Decks" scope.
    public var deckId: Int64
    public var deckName: String
    public var isAllDecksScope: Bool

    /// The card currently on screen, nil between cards / when finished.
    public var currentCardId: Int64?
    /// Note of the current card — lets an agent fetch the full note
    /// (all fields, tags) with one `get_note` call.
    public var currentNoteId: Int64?
    /// Template ordinal of the current card within its note.
    public var cardOrdinal: UInt32
    /// Cards still ahead in this session's display queue (excludes the
    /// card on screen).
    public var queueRemaining: Int
    public var isFinished: Bool
    /// Whether the back/answer side is currently revealed for the current card.
    /// Maps directly to `ReviewSession.showAnswer` (false = front/question visible,
    /// true = back/answer visible / card flipped).
    public var isAnswerRevealed: Bool

    /// This session's answers so far.
    public var reviewed: Int
    public var correct: Int
    /// Consecutive non-Again answers.
    public var streak: Int
    /// Remaining cards by category in the live queue.
    public var remainingNew: Int
    public var remainingLearning: Int
    public var remainingReview: Int

    /// Every answer given this session, oldest first. "Previous ones in
    /// today's review" for chat — cross-session history is the engine's
    /// revlog, not this.
    public var answered: [Answered]

    public struct Answered: Codable, Sendable, Equatable {
        public var cardId: Int64
        /// "again" | "hard" | "good" | "easy"
        public var rating: String
        /// Epoch milliseconds of the answer.
        public var atMs: Int64

        public init(cardId: Int64, rating: String, atMs: Int64) {
            self.cardId = cardId
            self.rating = rating
            self.atMs = atMs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAtMs, deckId, deckName, isAllDecksScope
        case currentCardId, currentNoteId, cardOrdinal, queueRemaining, isFinished
        case isAnswerRevealed
        case reviewed, correct, streak, remainingNew, remainingLearning, remainingReview
        case answered
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.schemaVersion
        updatedAtMs = try c.decode(Int64.self, forKey: .updatedAtMs)
        deckId = try c.decode(Int64.self, forKey: .deckId)
        deckName = try c.decode(String.self, forKey: .deckName)
        isAllDecksScope = try c.decode(Bool.self, forKey: .isAllDecksScope)
        currentCardId = try c.decodeIfPresent(Int64.self, forKey: .currentCardId)
        currentNoteId = try c.decodeIfPresent(Int64.self, forKey: .currentNoteId)
        cardOrdinal = try c.decode(UInt32.self, forKey: .cardOrdinal)
        queueRemaining = try c.decode(Int.self, forKey: .queueRemaining)
        isFinished = try c.decode(Bool.self, forKey: .isFinished)
        isAnswerRevealed = try c.decodeIfPresent(Bool.self, forKey: .isAnswerRevealed) ?? false
        reviewed = try c.decode(Int.self, forKey: .reviewed)
        correct = try c.decode(Int.self, forKey: .correct)
        streak = try c.decode(Int.self, forKey: .streak)
        remainingNew = try c.decode(Int.self, forKey: .remainingNew)
        remainingLearning = try c.decode(Int.self, forKey: .remainingLearning)
        remainingReview = try c.decode(Int.self, forKey: .remainingReview)
        answered = try c.decode([Answered].self, forKey: .answered)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encode(deckId, forKey: .deckId)
        try c.encode(deckName, forKey: .deckName)
        try c.encode(isAllDecksScope, forKey: .isAllDecksScope)
        try c.encodeIfPresent(currentCardId, forKey: .currentCardId)
        try c.encodeIfPresent(currentNoteId, forKey: .currentNoteId)
        try c.encode(cardOrdinal, forKey: .cardOrdinal)
        try c.encode(queueRemaining, forKey: .queueRemaining)
        try c.encode(isFinished, forKey: .isFinished)
        try c.encode(isAnswerRevealed, forKey: .isAnswerRevealed)
        try c.encode(reviewed, forKey: .reviewed)
        try c.encode(correct, forKey: .correct)
        try c.encode(streak, forKey: .streak)
        try c.encode(remainingNew, forKey: .remainingNew)
        try c.encode(remainingLearning, forKey: .remainingLearning)
        try c.encode(remainingReview, forKey: .remainingReview)
        try c.encode(answered, forKey: .answered)
    }

    public init(
        deckId: Int64,
        deckName: String,
        isAllDecksScope: Bool,
        currentCardId: Int64?,
        currentNoteId: Int64?,
        cardOrdinal: UInt32,
        queueRemaining: Int,
        isFinished: Bool,
        isAnswerRevealed: Bool = false,
        reviewed: Int,
        correct: Int,
        streak: Int,
        remainingNew: Int,
        remainingLearning: Int,
        remainingReview: Int,
        answered: [Answered]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.updatedAtMs = Int64(Date.now.timeIntervalSince1970 * 1000)
        self.deckId = deckId
        self.deckName = deckName
        self.isAllDecksScope = isAllDecksScope
        self.currentCardId = currentCardId
        self.currentNoteId = currentNoteId
        self.cardOrdinal = cardOrdinal
        self.queueRemaining = queueRemaining
        self.isFinished = isFinished
        self.isAnswerRevealed = isAnswerRevealed
        self.reviewed = reviewed
        self.correct = correct
        self.streak = streak
        self.remainingNew = remainingNew
        self.remainingLearning = remainingLearning
        self.remainingReview = remainingReview
        self.answered = answered
    }
}
