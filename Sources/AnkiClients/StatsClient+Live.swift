import AnkiBackend
import AnkiProtoBridge
public import Dependencies

extension StatsClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend

        return Self(
            fetchGraphs: { search, days in
                try await backendOffload { try backend.invoke(.graphs(search: search, days: days)) }
            },
            graduatedToday: { search in
                try await backendOffload {
                    // "Done for today" = answered today AND no longer in a
                    // learning/relearning state. `is:review` alone is
                    // type-based and matches lapsed cards (type=Relearn) —
                    // a card answered Again is NOT done: Anki keeps showing
                    // it today until it's re-graduated past the rollover.
                    // `-is:learn` (type Learn/Relearn) excludes those and
                    // mid-step learning cards alike.
                    let query = search.isEmpty ? "rated:1 -is:learn" : "rated:1 -is:learn \(search)"
                    return try backend.invoke(.searchCardIds(query: query)).count
                }
            },
            learningDueToday: { search in
                try await backendOffload {
                    // `prop:due<=0` is queue-aware in the engine (sqlwriter
                    // converts learn-queue epoch dues relative to the next
                    // day start), so this catches intraday learning due
                    // LATER today — which the deck-tree and queue learn
                    // counts drop once it's beyond the learn-ahead window.
                    let query = search.isEmpty
                        ? "is:learn prop:due<=0 -is:suspended -is:buried"
                        : "is:learn prop:due<=0 -is:suspended -is:buried \(search)"
                    return try backend.invoke(.searchCardIds(query: query)).count
                }
            },
            lastRating: { cardId in
                try await backendOffload { try backend.invoke(.lastCardRating(cardId: cardId)) }
            }
        )
    }()
}
