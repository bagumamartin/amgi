import Foundation
import AnkiClients
import AnkiKit

/// Per-deck review volume from the already-synced collection (Anki graphs /
/// revlog). No extra sync payload — each device infers the same ranking
/// after a collection sync.
enum DeckUsageRanking {
    static let lookbackDays = 365
    /// Reviews older than this many days contribute half as much as today's.
    /// Keeps "Most used" driven by recent activity instead of bulk volume
    /// from weeks or months ago.
    static let recencyHalfLifeDays = 7.0

    static func rank(from graphs: GraphsSnapshot?) -> DeckUsageRank {
        guard let graphs else { return DeckUsageRank() }
        var total = 0
        var lastActive = Int.min
        var weighted = 0.0
        for (offset, day) in graphs.reviews.count {
            let n = day.learn + day.relearn + day.young + day.mature + day.filtered
            guard n > 0 else { continue }
            total += n
            let daysAgo = Double(-offset)
            weighted += Double(n) * pow(0.5, daysAgo / recencyHalfLifeDays)
            if offset > lastActive { lastActive = offset }
        }
        return DeckUsageRank(
            reviewTotal: total,
            lastActiveOffset: lastActive,
            weightedScore: weighted
        )
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
        await withTaskGroup(of: (Int64, DeckUsageRank)?.self) { group in
            var iterator = decks.makeIterator()
            func enqueue() {
                guard let deck = iterator.next() else { return }
                group.addTask {
                    guard let graphs = try? await statsClient.fetchGraphs(
                        deckSearch(fullName: deck.fullName),
                        lookbackDays
                    ) else { return nil }
                    return (deck.id.rawValue, rank(from: graphs))
                }
            }
            for _ in 0..<min(4, decks.count) { enqueue() }
            var out: [Int64: DeckUsageRank] = [:]
            for await pair in group {
                if let pair { out[pair.0] = pair.1 }
                enqueue()
            }
            return out
        }
    }
}
