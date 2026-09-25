public import AmgiReader
public import AmgiReaderEPUB
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
    public var chapterContentURL: @Sendable (_ bookID: String, _ chapterID: Int64) async -> URL?
    /// Book content root, used as the WebView's read-access scope.
    public var contentRootURL: @Sendable (_ bookID: String) async -> URL?
    public var coverURL: @Sendable (_ bookID: String) async -> URL?
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
        let store = SharedEPUBLibraryStore.store
        return Self(
            importEPUB: { url in
                let book = try await store.importEPUB(from: url)
                await store.scheduleICloudSync()
                return book
            },
            listBooks: {
                await store.scheduleICloudSync()
                return await store.books()
            },
            syncWithICloud: { await store.synchronizeWithICloud() },
            remoteBookIDs: { await store.remoteBookIDs() },
            restoreFromICloud: { bookID in
                try await store.restoreFromICloud(bookID: bookID)
            },
            deleteBook: { bookID in
                try await store.delete(bookID: bookID)
                await store.scheduleICloudSync()
            },
            chapterContentURL: { bookID, chapterID in
                await store.contentURL(bookID: bookID, chapterID: chapterID)
            },
            contentRootURL: { bookID in await store.contentRootURL(bookID: bookID) },
            coverURL: { bookID in await store.coverURL(bookID: bookID) }
        )
    }()
}

private enum SharedEPUBLibraryStore {
    static let store = EPUBLibraryStore()
}
