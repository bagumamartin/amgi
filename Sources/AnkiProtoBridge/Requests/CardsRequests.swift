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
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.searchCards,
            encode: {
                var proto = Anki_Search_SearchRequest()
                proto.search = query.isEmpty ? "deck:*" : query
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
