import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

extension Request where Response == GraphsSnapshot {
    /// Fetches the full graphs payload (every chart series the dashboard
    /// needs) for the supplied search filter and lookback window.
    ///
    /// - Parameters:
    ///   - search: backend search expression (`""` means whole collection).
    ///   - days: lookback in days. Wire field is `UInt32`.
    public static func graphs(search: String, days: Int) -> Self {
        .decoded(
            serviceId: ServiceID.stats,
            methodId: StatsMethod.graphs,
            encode: {
                var req = Anki_Stats_GraphsRequest()
                req.search = search
                req.days = UInt32(max(0, days))
                return try req.serializedData()
            }
        )
    }
}

extension Request where Response == Rating? {
    /// The rating the card received on its most recent review, decoded from
    /// the last revlog entry; `nil` = the card has never been reviewed.
    public static func lastCardRating(cardId: Int64) -> Self {
        Self(
            serviceId: ServiceID.stats,
            methodId: StatsMethod.cardStats,
            encode: {
                var req = Anki_Cards_CardId()
                req.cid = cardId
                return try req.serializedData()
            },
            decode: { bytes in
                let response = try Anki_Stats_CardStatsResponse(serializedBytes: bytes)
                // Revlog `ease` is the ease FACTOR (e.g. 2500), NOT the
                // pressed button — the button lives in `button_chosen`.
                // `CardStatsResponse.revlog` is newest-first (see
                // `stats/card.rs:stats_revlog_entries_with_memory_state`), so
                // iterating forward walks newest → oldest. Skip entries
                // without a button (manual reschedules log button 0) to the
                // last real rating.
                for entry in response.revlog {
                    if let rating = Rating(rawValue: Int16(entry.buttonChosen)) {
                        return rating
                    }
                }
                return nil
            }
        )
    }
}
