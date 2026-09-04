public import AnkiKit
public import AnkiProtoBridge
public import Dependencies
import DependenciesMacros
@DependencyClient
public struct CardClient: Sendable {
    public var fetchDue: @Sendable (_ deckId: DeckID) async throws -> [CardRecord]
    public var fetchByNote: @Sendable (_ noteId: NoteID) async throws -> [CardRecord]
    public var getCard: @Sendable (_ cardId: CardID) async throws -> CardRecord
    public var save: @Sendable (_ card: CardRecord) async throws -> Void
    public var answer: @Sendable (_ cardId: CardID, _ rating: Rating, _ timeSpent: Int32) async throws -> Void
    public var undo: @Sendable (_ cardId: CardID) async throws -> Void
    /// Single-card suspend/bury for context menus; batch variants below.
    public var suspend: @Sendable (_ cardId: CardID) async throws -> Void
    public var bury: @Sendable (_ cardId: CardID) async throws -> Void
    public var flag: @Sendable (_ cardId: CardID, _ value: UInt32) async throws -> Void
    public var resetToNew: @Sendable (_ cardId: CardID) async throws -> Void
    public var undoLast: @Sendable () async throws -> Void
    public var redoLast: @Sendable () async throws -> Void
    public var undoStatus: @Sendable () async throws -> UndoStatusInfo
    public var getCardFlags: @Sendable (_ cardId: CardID) async throws -> UInt32
    public var hasUndoableAction: @Sendable () async throws -> Bool
    public var removeCards: @Sendable (_ cardIds: [CardID]) async throws -> Void
    /// Raw id search with engine-side ordering (spec D3).
    public var searchIds: @Sendable (_ query: String, _ order: SearchOrder?) async throws -> [CardID]

    // MARK: Batch operations (Browse selection bar)

    public var suspendCards: @Sendable (_ cardIds: [CardID], _ noteIds: [NoteID]) async throws -> Void
    public var restoreBuriedAndSuspended: @Sendable (_ cardIds: [CardID]) async throws -> Void
    public var buryUserCards: @Sendable (_ cardIds: [CardID], _ noteIds: [NoteID]) async throws -> Void
    public var setDueDate: @Sendable (_ cardIds: [CardID], _ daysExpression: String) async throws -> Void
    public var gradeNow: @Sendable (_ cardIds: [CardID], _ rating: Rating) async throws -> Void
    public var repositionCards: @Sendable (_ cardIds: [CardID], _ startingFrom: UInt32, _ stepSize: UInt32, _ randomize: Bool, _ shiftExisting: Bool) async throws -> Int
    public var changeDeck: @Sendable (_ cardIds: [CardID], _ deckId: DeckID) async throws -> Int
}

extension CardClient: TestDependencyKey {
    public static let testValue = CardClient()
}

extension DependencyValues {
    public var cardClient: CardClient {
        get { self[CardClient.self] }
        set { self[CardClient.self] = newValue }
    }
}
