import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - searchCardIds

extension Request where Response == [CardID] {
    /// Runs a card search and returns the matching card ids. Used for
    /// scheduling-state counts (e.g. `is:review rated:1` → cards graduated
    /// today). An empty query is rewritten to `deck:*` to match the existing
    /// service-level behaviour.
    public static func searchCardIds(query: String) -> Self {
        .searchCardIds(query: query, order: nil)
    }

    /// Same search with an engine-side builtin sort — sorting must never
    /// happen client-side over paged results. `column` keys come from
    /// `.allBrowserColumns()`.
    public static func searchCardIds(query: String, order: SearchOrder?) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.searchCards,
            encode: {
                var proto = Anki_Search_SearchRequest()
                proto.search = query.isEmpty ? "deck:*" : query
                if let order { proto.order = order.protoValue }
                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_Search_SearchResponse(serializedBytes: bytes)
                return resp.ids.map { CardID($0) }
            }
        )
    }
}

// MARK: - getCard

extension Request where Response == CardRecord {
    /// Fetches a single card record. The flag bits live in
    /// `CardRecord.flags & 0b111` — callers extract as needed.
    public static func getCard(id: CardID) -> Self {
        .decoded(
            serviceId: ServiceID.cards,
            methodId: CardsMethod.getCard,
            encode: {
                var proto = Anki_Cards_CardId()
                proto.cid = id.rawValue
                return try proto.serializedData()
            }
        )
    }
}

// MARK: - setFlag / removeCards (Void)

extension Request where Response == Void {
    /// Sets the user-visible flag color on the given cards. `flag: 0`
    /// clears the flag; values 1–7 map to the seven flag colors.
    public static func setFlag(cardIds: [CardID], flag: UInt32) -> Self {
        Self(
            serviceId: ServiceID.cards,
            methodId: CardsMethod.setFlag,
            encode: {
                var proto = Anki_Cards_SetFlagRequest()
                proto.cardIds = cardIds.map(\.rawValue)
                proto.flag = flag
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }

    /// Removes the given cards (and the parent note if all its cards
    /// disappear).
    public static func removeCards(cardIds: [CardID]) -> Self {
        Self(
            serviceId: ServiceID.cards,
            methodId: CardsMethod.removeCards,
            encode: {
                var proto = Anki_Cards_RemoveCardsRequest()
                proto.cardIds = cardIds.map(\.rawValue)
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - setDeck (move to deck)

extension Request where Response == Int {
    /// Moves cards to a deck — Browse "Change Deck" batch op. Returns
    /// the number of cards actually moved.
    public static func setDeck(cardIds: [CardID], deckId: DeckID) -> Self {
        Self(
            serviceId: ServiceID.cards,
            methodId: CardsMethod.setDeck,
            encode: {
                var proto = Anki_Cards_SetDeckRequest()
                proto.cardIds = cardIds.map(\.rawValue)
                proto.deckID = deckId.rawValue
                return try proto.serializedData()
            },
            decode: { bytes in
                Int(try Anki_Collection_OpChangesWithCount(serializedBytes: bytes).count)
            }
        )
    }
}

// MARK: - updateCards (save)

extension Request where Response == Void {
    /// Persists edited card fields (deck, due, queue…) as one undoable
    /// operation. Used by CardClient.save.
    public static func updateCards(cards: [CardRecord]) -> Self {
        Self(
            serviceId: ServiceID.cards,
            methodId: CardsMethod.updateCards,
            encode: {
                var proto = Anki_Cards_UpdateCardsRequest()
                proto.cards = cards.map(Self.makeCardProto)
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }

    static func makeCardProto(_ card: CardRecord) -> Anki_Cards_Card {
        var proto = Anki_Cards_Card()
        proto.id = card.id.rawValue
        proto.noteID = card.nid.rawValue
        proto.deckID = card.did.rawValue
        proto.templateIdx = UInt32(card.ord)
        proto.mtimeSecs = card.mod
        proto.usn = card.usn
        proto.ctype = UInt32(UInt16(bitPattern: card.type))
        proto.queue = Int32(card.queue)
        proto.due = card.due
        proto.interval = UInt32(card.ivl)
        proto.easeFactor = UInt32(card.factor)
        proto.reps = UInt32(card.reps)
        proto.lapses = UInt32(card.lapses)
        proto.remainingSteps = UInt32(card.left)
        proto.originalDue = card.odue
        proto.originalDeckID = card.odid.rawValue
        proto.flags = UInt32(card.flags)
        proto.customData = card.data
        return proto
    }
}
