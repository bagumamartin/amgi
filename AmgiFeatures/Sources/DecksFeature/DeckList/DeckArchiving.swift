import AnkiKit
import Foundation

/// Library archive rule: fully suspended top-level decks leave the
/// Decks section. Anki's built-in Default deck (`id == 1`) and filtered
/// Custom Study decks stay put even when every card is parked.
enum DeckArchiving {
    static let defaultDeckID = DeckID(1)

    static func isExempt(id: DeckID, isFiltered: Bool) -> Bool {
        isFiltered || id == defaultDeckID
    }

    /// Empty decks are not archived — they never had cards to park.
    static func isFullySuspended(totalCards: Int, suspendedCards: Int) -> Bool {
        totalCards > 0 && suspendedCards >= totalCards
    }
}
