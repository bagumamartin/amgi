public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct StatsClient: Sendable {
    public var fetchGraphs: @Sendable (_ search: String, _ days: Int) async throws -> GraphsSnapshot
    /// Cards that graduated today in the given scope — answered today and now
    /// scheduled for a future Anki day. `search` is a backend search expression
    /// (`""` = whole collection).
    public var graduatedToday: @Sendable (_ search: String) async throws -> Int
    /// Learning/relearning cards still due before the current Anki day ends —
    /// including intraday steps beyond the scheduler's learn-ahead window,
    /// which the deck-tree and queue counts silently drop. Excludes buried
    /// and suspended cards. `search` scopes it (`""` = whole collection).
    public var learningDueToday: @Sendable (_ search: String) async throws -> Int
    /// The rating the card received on its most recent review, from the last
    /// revlog entry. `nil` for cards never reviewed (new cards).
    public var lastRating: @Sendable (_ cardId: Int64) async throws -> Rating?
    /// Past days as the deck list showed them: due at the start, studied,
    /// left at the end. `deckID` 0 is the whole collection.
    public var studyLedger: @Sendable (_ deckID: Int64, _ rolloverHour: Int, _ days: [StudyLedger.Window], _ detailOffset: Int?) async throws -> StudyLedger
    /// When each answer in `[startMs, endMs)` was given, as UTC millis,
    /// ascending. Counts the same answers as `fetchGraphs`' review totals.
    public var reviewTimes: @Sendable (_ scope: String, _ startMs: Int64, _ endMs: Int64) async throws -> [Int64]
    /// Each card's first review in `[startMs, endMs)` with the answer before
    /// it — how Study tells which future day a review-ahead answer cleared.
    public var reviewAhead: @Sendable (_ scope: String, _ startMs: Int64, _ endMs: Int64) async throws -> [ReviewAheadAnswer]
}

extension StatsClient: TestDependencyKey {
    public static let testValue = StatsClient()
}

extension DependencyValues {
    public var statsClient: StatsClient {
        get { self[StatsClient.self] }
        set { self[StatsClient.self] = newValue }
    }
}
