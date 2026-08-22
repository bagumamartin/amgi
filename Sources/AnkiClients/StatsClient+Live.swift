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
                    let query = search.isEmpty ? "is:review rated:1" : "is:review rated:1 \(search)"
                    return try backend.invoke(.searchCardIds(query: query)).count
                }
            }
        )
    }()
}
