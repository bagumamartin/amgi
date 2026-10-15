public import AmgiReader
public import Dependencies
import AnkiKit
import DependenciesMacros

/// Cross-device sync for library collections, through the app's iCloud Drive
/// container like reading progress — never through the Anki collection.
/// The local `ReaderCollectionStore` stays the source of truth on each
/// device; this client merges it with the other devices' copies.
@DependencyClient
public struct ReaderCollectionSyncClient: Sendable {
    /// The tree other devices have synced, or nil if there is none yet or
    /// iCloud is unavailable.
    public var load: @Sendable () async -> ReaderCollectionTree?
    /// Merges `tree` into the cloud copy and returns the merged tree.
    public var push: @Sendable (_ tree: ReaderCollectionTree) async throws -> ReaderCollectionTree
}

extension ReaderCollectionSyncClient: TestDependencyKey {
    public static let testValue = ReaderCollectionSyncClient()
}

extension ReaderCollectionSyncClient: DependencyKey {
    public static let liveValue = ReaderCollectionSyncClient(
        load: {
            await ReaderCollectionsICloudStore.load(profileID: ProfileScope.current())
        },
        push: { tree in
            try await ReaderCollectionsICloudStore.push(tree, profileID: ProfileScope.current())
        }
    )
}

extension DependencyValues {
    public var readerCollectionSyncClient: ReaderCollectionSyncClient {
        get { self[ReaderCollectionSyncClient.self] }
        set { self[ReaderCollectionSyncClient.self] = newValue }
    }
}
