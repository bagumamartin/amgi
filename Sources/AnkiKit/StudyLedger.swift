import Foundation

/// Past Anki days as the deck list would have shown them, rebuilt from the
/// collection by the bridge (`anki-bridge-rs/src/study_ledger.rs`).
///
/// - `due`: the deck list at the start of the day, daily limits applied.
/// - `studied`: answers recorded that day. Exact.
/// - `left`: the deck list at the end of the day, after studying.
///
/// A day is `exact` unless `uncertain` names a cause. Deck membership and
/// deck options are taken as they are now; `limitsExceeded` reports decks
/// where that day's studying proves the options were different.
public struct StudyLedger: Equatable, Sendable, Codable {
    public struct Counts: Equatable, Sendable, Codable {
        public var new: Int
        public var learn: Int
        public var review: Int

        public init(new: Int = 0, learn: Int = 0, review: Int = 0) {
            self.new = new
            self.learn = learn
            self.review = review
        }

        public var total: Int { new + learn + review }
    }

    public struct Studied: Equatable, Sendable, Codable {
        /// Cards introduced that day.
        public var new: Int
        /// Cards whose first answer of the day was a (re)learning step.
        public var learn: Int
        /// Cards whose first answer of the day was a review.
        public var review: Int
        public var cards: Int
        public var answers: Int
        public var millis: Int

        public init(new: Int = 0, learn: Int = 0, review: Int = 0, cards: Int = 0, answers: Int = 0, millis: Int = 0) {
            self.new = new
            self.learn = learn
            self.review = review
            self.cards = cards
            self.answers = answers
            self.millis = millis
        }
    }

    public struct Uncertain: Equatable, Sendable, Codable {
        public var incompleteLog: Int
        public var manualSchedule: Int
        public var ambiguousState: Int
        public var learningRollover: Int
        public var suspensionUnknown: Int
        /// Decks where more was studied than today's options allow.
        public var limitsExceeded: [String]

        public init(
            incompleteLog: Int = 0,
            manualSchedule: Int = 0,
            ambiguousState: Int = 0,
            learningRollover: Int = 0,
            suspensionUnknown: Int = 0,
            limitsExceeded: [String] = []
        ) {
            self.incompleteLog = incompleteLog
            self.manualSchedule = manualSchedule
            self.ambiguousState = ambiguousState
            self.learningRollover = learningRollover
            self.suspensionUnknown = suspensionUnknown
            self.limitsExceeded = limitsExceeded
        }

        /// Cards whose state that day the log does not establish.
        public var unplacedCards: Int { incompleteLog + manualSchedule + ambiguousState + learningRollover }
    }

    public struct DeckRow: Equatable, Sendable, Codable {
        public var deckId: Int64
        public var name: String
        public var due: Counts
        public var studiedCards: Int
        public var left: Counts

        public init(deckId: Int64, name: String, due: Counts, studiedCards: Int, left: Counts) {
            self.deckId = deckId
            self.name = name
            self.due = due
            self.studiedCards = studiedCards
            self.left = left
        }
    }

    public struct Detail: Equatable, Sendable, Codable {
        /// Every learning/review card still due at the day's end, before
        /// limits — the cards a catch-up session would show.
        public var leftLearningIds: [Int64]
        public var leftReviewIds: [Int64]
        public var decks: [DeckRow]

        public init(leftLearningIds: [Int64] = [], leftReviewIds: [Int64] = [], decks: [DeckRow] = []) {
            self.leftLearningIds = leftLearningIds
            self.leftReviewIds = leftReviewIds
            self.decks = decks
        }

        public var leftIds: [Int64] { (leftLearningIds + leftReviewIds).sorted() }
    }

    public struct Day: Equatable, Sendable, Codable {
        /// Days before today.
        public var offset: Int
        public var due: Counts
        public var studied: Studied
        public var left: Counts
        public var uncertain: Uncertain
        public var exact: Bool
        public var detail: Detail?

        public init(
            offset: Int,
            due: Counts,
            studied: Studied,
            left: Counts,
            uncertain: Uncertain = Uncertain(),
            exact: Bool = true,
            detail: Detail? = nil
        ) {
            self.offset = offset
            self.due = due
            self.studied = studied
            self.left = left
            self.uncertain = uncertain
            self.exact = exact
            self.detail = detail
        }
    }

    /// One Anki day to rebuild. Bounds are UTC millis (`revlog.id`); a day
    /// still in progress ends now.
    public struct Window: Equatable, Sendable {
        public var offset: Int
        public var startMs: Int64
        public var endMs: Int64

        public init(offset: Int, startMs: Int64, endMs: Int64) {
            self.offset = offset
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public var days: [Day]

    public init(days: [Day]) {
        self.days = days
    }

    /// Numeric IDs only. Never return an empty query, which would browse all cards.
    public static func search(ids: [Int64]) -> String {
        let ids = Set(ids).filter { $0 > 0 }.sorted()
        return ids.isEmpty ? "cid:0" : "cid:" + ids.map(String.init).joined(separator: ",")
    }
}
