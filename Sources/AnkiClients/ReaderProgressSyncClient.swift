public import AmgiReader
public import Dependencies
import DependenciesMacros

/// Cross-device sync adapter for `ReaderProgressStore`. The store persists
/// per-book progress locally to UserDefaults; this client mirrors writes
/// into the app's iCloud Drive container so the same progress reaches the
/// user's other devices without ever touching the Anki collection.
///
/// Book data syncs through iCloud, Anki notes through AnkiWeb, and the two
/// never mix: reading a book must not dirty the collection or trigger an
/// Anki sync on its own. (Cards made from books are Anki notes like any
/// other, and keep syncing through AnkiWeb.)
///
/// Lives in `AnkiClients` for history — it began as an Anki collection-config
/// bridge — rather than in `AmgiReader`, which stays free of sync concerns.
@DependencyClient
public struct ReaderProgressSyncClient: Sendable {
    /// Returns the merged manifest of book → progress entries that the
    /// Anki collection currently holds, or nil if nothing has been
    /// synced yet from any device.
    public var loadManifest: @Sendable () async throws -> ReaderProgressManifest?
    /// Pushes a single book's progress into the collection config and
    /// returns the resulting manifest. Idempotent on identical writes.
    public var pushBookProgress: @Sendable (
        _ bookID: String,
        _ payload: ReaderSavedProgress
    ) async throws -> ReaderProgressManifest
}

extension ReaderProgressSyncClient: TestDependencyKey {
    public static let testValue = ReaderProgressSyncClient()
}

extension DependencyValues {
    public var readerProgressSyncClient: ReaderProgressSyncClient {
        get { self[ReaderProgressSyncClient.self] }
        set { self[ReaderProgressSyncClient.self] = newValue }
    }
}

/// JSON-encoded shape of the per-profile iCloud Drive progress manifest.
/// One file per profile under `Documents/ReaderProgress/`; each maps book ID
/// to its latest payload, merged last-write-wins per book.
public struct ReaderProgressManifest: Codable, Sendable, Equatable {
    public var version: Int
    public var entries: [String: ReaderSavedProgress]

    public init(version: Int = 1, entries: [String: ReaderSavedProgress] = [:]) {
        self.version = version
        self.entries = entries
    }
}
