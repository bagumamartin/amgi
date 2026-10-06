public import AmgiReader
public import AmgiReaderEPUB
import AnkiKit
public import Dependencies
public import Foundation
import DependenciesMacros

@DependencyClient
public struct EPUBLibraryClient: Sendable {
    public var importEPUB: @Sendable (_ sourceURL: URL) async throws -> ReaderBook
    public var listBooks: @Sendable () async -> [ReaderBook] = { [] }
    /// Best-effort background backup mirror for the managed EPUB library.
    /// Reading progress continues through the existing Anki collection-config
    /// sync; this mirror owns source files and library metadata.
    public var syncWithICloud: @Sendable () async -> EPUBICloudSyncResult = { .unavailable }
    /// IDs available in the private iCloud backup, for an explicit restore
    /// surface. Background synchronization also restores additive entries.
    public var remoteBookIDs: @Sendable () async -> [String] = { [] }
    /// Restore one explicitly selected cloud book through the local EPUB
    /// validation/import pipeline.
    public var restoreFromICloud: @Sendable (_ bookID: String) async throws -> ReaderBook = { _ in
        throw EPUBLibraryCloudError.sourceUnavailable
    }
    public var deleteBook: @Sendable (_ bookID: String) async throws -> Void
    /// Repair state for every managed book, keyed by book ID. A book whose
    /// source went missing or stopped parsing is reported here instead of
    /// silently vanishing from `listBooks`.
    public var bookHealth: @Sendable () async -> [String: EPUBLibraryBookHealth] = { [:] }
    /// Re-parse one book in place, clearing its fault if the source is
    /// readable again. Returns nil when it is still broken.
    public var retryBook: @Sendable (_ bookID: String) async -> ReaderBook? = { _ in nil }
    /// Adopt a user-picked replacement file for a book whose stored source is
    /// missing or corrupt. Throws when the replacement is a different book.
    public var relinkBook: @Sendable (
        _ bookID: String,
        _ replacementURL: URL
    ) async throws -> ReaderBook = { _, _ in
        throw EPUBLibraryStore.StoreError.bookNotFound
    }
    public var chapterContentURL: @Sendable (_ bookID: String, _ chapterID: Int64) async -> URL?
    /// Book content root, used as the WebView's read-access scope.
    public var contentRootURL: @Sendable (_ bookID: String) async -> URL?
    public var coverURL: @Sendable (_ bookID: String) async -> URL? = { _ in nil }
    /// Retrieves a fully parsed ReaderBook on demand.
    public var book: @Sendable (_ bookID: String) async -> ReaderBook? = { _ in nil }
}

extension EPUBLibraryClient: TestDependencyKey {
    public static let testValue = EPUBLibraryClient()
}

extension DependencyValues {
    public var epubLibraryClient: EPUBLibraryClient {
        get { self[EPUBLibraryClient.self] }
        set { self[EPUBLibraryClient.self] = newValue }
    }
}

extension EPUBLibraryClient: DependencyKey {
    public static let liveValue: Self = {
        // Every closure re-resolves the store for the profile that is active
        // at call time rather than capturing one at dependency-resolution
        // time. `RootView` re-ids the reader tree on profile switch, but a
        // stale capture would still hand the previous profile's books to the
        // freshly-built UI.
        Self(
            importEPUB: { url in
                let store = SharedEPUBLibraryStore.store()
                let book = try await store.importEPUB(from: url)
                await store.scheduleICloudSync()
                return book
            },
            listBooks: {
                let store = SharedEPUBLibraryStore.store()
                await store.scheduleICloudSync()
                return await store.books()
            },
            syncWithICloud: { await SharedEPUBLibraryStore.store().synchronizeWithICloud() },
            remoteBookIDs: { await SharedEPUBLibraryStore.store().remoteBookIDs() },
            restoreFromICloud: { bookID in
                try await SharedEPUBLibraryStore.store().restoreFromICloud(bookID: bookID)
            },
            deleteBook: { bookID in
                let store = SharedEPUBLibraryStore.store()
                try await store.delete(bookID: bookID)
                await store.scheduleICloudSync()
            },
            bookHealth: { await SharedEPUBLibraryStore.store().bookHealth() },
            retryBook: { bookID in await SharedEPUBLibraryStore.store().retryBook(bookID: bookID) },
            relinkBook: { bookID, url in
                try await SharedEPUBLibraryStore.store().relinkBook(bookID: bookID, to: url)
            },
            chapterContentURL: { bookID, chapterID in
                await SharedEPUBLibraryStore.store().contentURL(bookID: bookID, chapterID: chapterID)
            },
            contentRootURL: { bookID in
                await SharedEPUBLibraryStore.store().contentRootURL(bookID: bookID)
            },
            coverURL: { bookID in
                await SharedEPUBLibraryStore.store().coverURL(bookID: bookID)
            },
            book: { bookID in
                await SharedEPUBLibraryStore.store().book(bookID: bookID)
            }
        )
    }()
}

/// Per-profile EPUB library roots.
///
/// The library used to be one process-wide singleton rooted at a fixed
/// `Application Support/Amgi/EPUBLibrary`, which meant switching profiles
/// kept showing the previous profile's books and deleting a book in one
/// profile hid it in the other. Rooting each store under the canonical
/// `CollectionLayout.profileDirectory(for:)` makes the EPUB library obey the
/// same ownership rule as the collection it belongs to.
private enum SharedEPUBLibraryStore {
    private static let registry = StoreRegistry()

    static func store() -> EPUBLibraryStore {
        registry.store(for: ProfileScope.current())
    }

    static func store(for profileID: String) -> EPUBLibraryStore {
        registry.store(for: profileID)
    }

    /// Lock-guarded cache. `EPUBLibraryStore` is an actor, so handing the
    /// same instance back is the point: the in-memory book/chapter caches
    /// survive across calls, and the actor serialises its own disk I/O.
    private final class StoreRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: EPUBLibraryStore] = [:]

        func store(for profileID: String) -> EPUBLibraryStore {
            lock.lock()
            defer { lock.unlock() }
            if let existing = stores[profileID] { return existing }
            let created = EPUBLibraryStore(
                rootDirectory: CollectionLayout.profileDirectory(for: profileID)
                    .appendingPathComponent("EPUB", isDirectory: true)
            )
            stores[profileID] = created
            return created
        }
    }
}
