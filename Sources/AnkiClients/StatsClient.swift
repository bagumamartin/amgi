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
