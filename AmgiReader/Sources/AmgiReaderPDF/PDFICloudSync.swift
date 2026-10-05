import Foundation

/// Configuration for the app-owned iCloud Drive container used by the PDF
/// library. The container itself is shared with the rest of the reader — see
/// `ReaderICloudConfiguration` — so book files and reading progress sync
/// through one home and neither touches the Anki collection.
public enum PDFICloudConfiguration {
    public static let libraryDirectoryName = "PDF"
}

/// Errors raised by an explicit cloud restore. Ordinary background mirroring
/// is best effort and reports failures through ``PDFICloudSyncResult``.
public enum PDFLibraryCloudError: Error, Sendable {
    case invalidBookID
    case bookNotFound
    case sourceUnavailable
}

/// A best-effort result for one background mirror pass. The local library
/// remains fully usable when iCloud is unavailable or a remote file cannot be
/// materialized. Cloud-only books are restored additively; cloud deletions are
/// never propagated.
public struct PDFICloudSyncResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case unavailable
        case completed
        case failed
    }

    public var status: Status
    public var uploadedBookIDs: [String]
    public var restoredBookIDs: [String]
    public var message: String?

    public init(
        status: Status,
        uploadedBookIDs: [String] = [],
        restoredBookIDs: [String] = [],
        message: String? = nil
    ) {
        self.status = status
        self.uploadedBookIDs = uploadedBookIDs
        self.restoredBookIDs = restoredBookIDs
        self.message = message
    }

    public static let unavailable = Self(status: .unavailable)
}

/// Metadata stored beside each content-addressed cloud book. There is no
/// shared mutable catalog: each book owns its own file, so independent device
/// additions cannot overwrite one another's manifest.
internal struct PDFCloudBookMetadata: Codable, Sendable, Hashable {
    var version: Int
    var bookID: String
    var title: String
    var author: String?
    var coverFileName: String?
    var language: String?
    var pageCount: Int
    var updatedAt: Date?

    init(
        version: Int = 1,
        bookID: String,
        title: String,
        author: String?,
        coverFileName: String? = nil,
        language: String? = nil,
        pageCount: Int,
        updatedAt: Date?
    ) {
        self.version = version
        self.bookID = bookID
        self.title = title
        self.author = author
        self.coverFileName = coverFileName
        self.language = language
        self.pageCount = pageCount
        self.updatedAt = updatedAt
    }
}

internal enum PDFICloudStorage {
    static func libraryURL(
        containerIdentifier: String,
        overrideRoot: URL?
    ) -> URL? {
        let base: URL
        if let overrideRoot {
            base = overrideRoot
        } else if FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(
                      forUbiquityContainerIdentifier: containerIdentifier
                  ) {
            base = container
        } else {
            return nil
        }

        return base
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(
                PDFICloudConfiguration.libraryDirectoryName,
                isDirectory: true
            )
    }

    static func isSafeBookID(_ bookID: String) -> Bool {
        bookID.hasPrefix("pdf-")
            && bookID.count <= 128
            && bookID.allSatisfy {
                $0.isLetter || $0.isNumber || "-_.".contains($0)
            }
    }

    static func bookDirectory(
        _ bookID: String,
        under libraryURL: URL
    ) -> URL? {
        guard isSafeBookID(bookID) else { return nil }
        return libraryURL
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookID, isDirectory: true)
    }

    static func metadataURL(for bookDirectory: URL) -> URL {
        bookDirectory.appendingPathComponent("metadata.json")
    }

    static func readMetadata(at bookDirectory: URL) throws -> PDFCloudBookMetadata {
        let data = try Data(contentsOf: metadataURL(for: bookDirectory))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let metadata = try? decoder.decode(PDFCloudBookMetadata.self, from: data) {
            return metadata
        }

        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        return try legacyDecoder.decode(PDFCloudBookMetadata.self, from: data)
    }

    static func writeMetadata(
        _ metadata: PDFCloudBookMetadata,
        at bookDirectory: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(metadata)
            let destination = metadataURL(for: bookDirectory)
            let temporary = bookDirectory.appendingPathComponent(
                ".metadata-\(UUID().uuidString)"
            )
            try data.write(to: temporary, options: .atomic)
            defer { try? fileManager.removeItem(at: temporary) }
            try replaceItemSynchronously(at: temporary, with: destination)
        }.value
    }

    static func remoteBookIDs(in libraryURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        let booksURL = libraryURL.appendingPathComponent("books", isDirectory: true)
        guard fileManager.fileExists(atPath: booksURL.path) else { return [] }

        return try fileManager.contentsOfDirectory(
            at: booksURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url in
            let bookID = url.lastPathComponent
            guard isSafeBookID(bookID) else { return nil }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return bookID
        }
        .sorted()
    }

    static func replaceItem(at source: URL, with destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try replaceItemSynchronously(at: source, with: destination)
        }.value
    }

    private static func replaceItemSynchronously(at source: URL, with destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".amgi-sync-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        try coordinatedCopy(from: source, to: temporary)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var replacementError: (any Error)?
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedDestination in
            do {
                if fileManager.fileExists(atPath: coordinatedDestination.path) {
                    _ = try fileManager.replaceItemAt(
                        coordinatedDestination,
                        withItemAt: temporary
                    )
                } else {
                    try fileManager.moveItem(
                        at: temporary,
                        to: coordinatedDestination
                    )
                }
            } catch {
                replacementError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let replacementError { throw replacementError }
    }

    /// Start and await an iCloud placeholder download without blocking a
    /// cooperative executor thread with a run-loop polling loop.
    static func ensureDownloaded(at url: URL) async throws {
        let fileManager = FileManager.default
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])

        // Local test/cache files and already materialized files do not need
        // an iCloud download request.
        guard values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }

        try fileManager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            let current = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
            ])
            if current.ubiquitousItemDownloadingStatus == .current { return }
        }

        throw PDFLibraryCloudError.sourceUnavailable
    }

    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: (any Error)?

        coordinator.coordinate(
            readingItemAt: source,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
