import AnkiClients
import AnkiKit

/// Per-deck review volume from the already-synced collection (Anki graphs /
/// revlog). No extra sync payload — each device infers the same ranking
/// after a collection sync.
enum DeckUsageRanking {
    static let lookbackDays = 365

    static func rank(from graphs: GraphsSnapshot?) -> DeckUsageRank {
        guard let graphs else { return DeckUsageRank() }
        var total = 0
        var lastActive = Int.min
        for (offset, day) in graphs.reviews.count {
            let n = day.learn + day.relearn + day.young + day.mature + day.filtered
            guard n > 0 else { continue }
            total += n
            if offset > lastActive { lastActive = offset }
        }
        return DeckUsageRank(reviewTotal: total, lastActiveOffset: lastActive)
    }

    static func deckSearch(fullName: String) -> String {
        let escaped = fullName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "deck:\"\(escaped)\""
    }

    static func ranks(
        for decks: [(id: DeckID, fullName: String)],
        statsClient: StatsClient
    ) async -> [Int64: DeckUsageRank] {
        await withTaskGroup(of: (Int64, DeckUsageRank).self) { group in
            for deck in decks {
                group.addTask {
                    let graphs = try? await statsClient.fetchGraphs(
                        deckSearch(fullName: deck.fullName),
                        lookbackDays
                    )
                    return (deck.id.rawValue, rank(from: graphs))
                }
            }
            var out: [Int64: DeckUsageRank] = [:]
            for await pair in group {
                out[pair.0] = pair.1
            }
            return out
        }
    }
}
