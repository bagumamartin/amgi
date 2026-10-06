public import AmgiReader
public import AmgiReaderPDF
import AnkiKit
public import Dependencies
public import Foundation
import DependenciesMacros

/// The app's seam onto the managed PDF library.
///
/// Shaped like `EPUBLibraryClient` on purpose: the library model already merges
/// two sources and repairs two sources, and a third bespoke client would be a
/// third set of call sites to keep in step. Keeping the two symmetrical is what
/// makes "one library, several kinds of book" read as one thing rather than as
/// an EPUB library with a PDF annex.
@DependencyClient
public struct PDFLibraryClient: Sendable {
    public var importPDF: @Sendable (_ sourceURL: URL) async throws -> ReaderBook
    public var listBooks: @Sendable () async -> [ReaderBook] = { [] }
    /// Best-effort background backup mirror for the managed PDF library.
    /// Reading progress continues through the iCloud Drive progress manifest;
    /// this mirror owns source files and library metadata.
    public var syncWithICloud: @Sendable () async -> PDFICloudSyncResult = { .unavailable }
    /// IDs available in the private iCloud backup, for an explicit restore
    /// surface. Background synchronization also restores additive entries.
    public var remoteBookIDs: @Sendable () async -> [String] = { [] }
    /// Restore one explicitly selected cloud book through the local PDF
    /// validation/import pipeline.
    public var restoreFromICloud: @Sendable (_ bookID: String) async throws -> ReaderBook = { _ in
        throw PDFLibraryStore.StoreError.bookNotFound
    }
    public var deleteBook: @Sendable (_ bookID: String) async throws -> Void
    /// Repair state for every managed book, keyed by book ID. A book whose
    /// source went missing or stopped parsing is reported here instead of
    /// silently vanishing from `listBooks`.
    public var bookHealth: @Sendable () async -> [String: PDFLibraryBookHealth] = { [:] }
    /// Re-read one book in place, clearing its fault if the source is readable
    /// again. Returns nil when it is still broken.
    public var retryBook: @Sendable (_ bookID: String) async -> ReaderBook? = { _ in nil }
    /// Adopt a user-picked replacement file. Throws when the replacement is a
    /// different document — the old file's annotations are real work, and a
    /// relink that quietly swapped in other pages would strand them.
    public var relinkBook: @Sendable (
        _ bookID: String,
        _ replacementURL: URL
    ) async throws -> ReaderBook = { _, _ in
        throw PDFLibraryStore.StoreError.bookNotFound
    }
    /// The managed file, which is also where annotations are written.
    public var sourceURL: @Sendable (_ bookID: String) async -> URL?
    /// The full parsed descriptor: page labels, outline, fingerprint, text-layer
    /// coverage.
    public var descriptor: @Sendable (_ bookID: String) async -> PDFDocumentDescriptor?
    /// Append an incremental update to the managed file.
    public var appendUpdate: @Sendable (_ bookID: String, _ update: [UInt8]) async throws -> Void = { _, _ in }
    /// Re-read the managed file after it has been written to.
    public var reload: @Sendable (_ bookID: String) async throws -> PDFDocumentDescriptor = { _ in
        throw PDFLibraryStore.StoreError.bookNotFound
    }
    public var coverURL: @Sendable (_ bookID: String) async -> URL? = { _ in nil }
    /// Retrieves a fully parsed ReaderBook on demand.
    public var book: @Sendable (_ bookID: String) async -> ReaderBook? = { _ in nil }
}

extension PDFLibraryClient: TestDependencyKey {
    public static let testValue = PDFLibraryClient()
}

extension DependencyValues {
    public var pdfLibraryClient: PDFLibraryClient {
        get { self[PDFLibraryClient.self] }
        set { self[PDFLibraryClient.self] = newValue }
    }
}

extension PDFLibraryClient: DependencyKey {
    public static let liveValue: Self = {
        // Every closure re-resolves the store for the profile active at call
        // time, for the same reason the EPUB client does: a captured store would
        // hand the previous profile's books to freshly-built UI after a switch.
        Self(
            importPDF: { url in
                let store = SharedPDFLibraryStore.store()
                let book = try await store.importPDF(from: url)
                await store.scheduleICloudSync()
                return book
            },
            listBooks: {
                let store = SharedPDFLibraryStore.store()
                await store.scheduleICloudSync()
                return await store.books()
            },
            syncWithICloud: { await SharedPDFLibraryStore.store().synchronizeWithICloud() },
            remoteBookIDs: { await SharedPDFLibraryStore.store().remoteBookIDs() },
            restoreFromICloud: { bookID in
                try await SharedPDFLibraryStore.store().restoreFromICloud(bookID: bookID)
            },
            deleteBook: { bookID in
                let store = SharedPDFLibraryStore.store()
                try await store.delete(bookID: bookID)
                await store.scheduleICloudSync()
            },
            bookHealth: { await SharedPDFLibraryStore.store().bookHealth() },
            retryBook: { bookID in await SharedPDFLibraryStore.store().retryBook(bookID: bookID) },
            relinkBook: { bookID, url in
                try await SharedPDFLibraryStore.store().relinkBook(bookID: bookID, to: url)
            },
            sourceURL: { bookID in await SharedPDFLibraryStore.store().sourceURL(bookID: bookID) },
            descriptor: { bookID in await SharedPDFLibraryStore.store().descriptor(bookID: bookID) },
            appendUpdate: { bookID, update in
                _ = try await SharedPDFLibraryStore.store().append(to: bookID, update: update)
            },
            reload: { bookID in try await SharedPDFLibraryStore.store().reload(bookID: bookID) },
            coverURL: { bookID in
                guard let url = await SharedPDFLibraryStore.store().sourceURL(bookID: bookID)?
                    .deletingLastPathComponent()
                    .appendingPathComponent("cover.jpg"),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            },
            book: { bookID in
                await SharedPDFLibraryStore.store().book(bookID: bookID)
            }
        )
    }()
}

/// Per-profile PDF library roots.
///
/// Under the same `CollectionLayout.profileDirectory(for:)` rule as the EPUB
/// library, so a profile's PDFs belong to that profile exactly as its books
/// belong to it. Sharing one store across profiles would show the previous
/// profile's documents in the library.
enum SharedPDFLibraryStore {
    private static let registry = StoreRegistry()

    static func store() -> PDFLibraryStore {
        registry.store(for: ProfileScope.current())
    }

    static func store(for profileID: String) -> PDFLibraryStore {
        registry.store(for: profileID)
    }

    /// Lock-guarded cache. `PDFLibraryStore` is an actor, so handing back the
    /// same instance keeps its in-memory caches warm and lets it serialise its
    /// own disk I/O — which matters more here than for EPUB, because a PDF's
    /// annotations are written to the file it is reading.
    private final class StoreRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: PDFLibraryStore] = [:]

        func store(for profileID: String) -> PDFLibraryStore {
            lock.lock()
            defer { lock.unlock() }
            if let existing = stores[profileID] { return existing }
            let created = PDFLibraryStore(
                rootDirectory: CollectionLayout.profileDirectory(for: profileID)
                    .appendingPathComponent("PDF", isDirectory: true)
            )
            stores[profileID] = created
            return created
        }
    }
}
