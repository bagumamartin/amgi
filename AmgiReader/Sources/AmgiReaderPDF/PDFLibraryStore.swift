public import Foundation
public import AmgiReader
import CryptoKit

/// The managed PDF library: imported files, their metadata, and their faults.
///
/// ## The source file is the annotation store
///
/// Unlike an EPUB — where the extraction directory is a disposable cache and
/// `original.epub` is an untouched archive — a PDF's managed file *is* the live
/// document. Annotations are appended to it (see `PDFIncrementalUpdate`), so the
/// file grows as the user reads. Three consequences shape this store:
///
/// - **The book ID must not depend on the whole file.** A content hash of the
///   bytes would change on the first annotation, and re-importing the file the
///   user just annotated would fork a second library entry. `deriveBookID`
///   hashes a prefix instead, which is stable under appends.
/// - **Writes are appends, so a crash mid-write is survivable.** A partially
///   written section is ignored by every reader, because the `startxref` that
///   would point at it is written last. That is why no backup directory is
///   needed here the way the EPUB store keeps one.
/// - **Reading and writing must not overlap.** The store is an actor, so
///   `append` and `read` cannot interleave, and a reload after each append
///   always sees a complete file.
public actor PDFLibraryStore {
    public enum StoreError: Error, Equatable, LocalizedError, Sendable {
        case bookNotFound
        case importFailed(underlying: String)
        case relinkMismatch(expected: String, found: String)
        case unreadableSource(String)

        public var errorDescription: String? {
            switch self {
            case .bookNotFound: "That PDF is no longer in the library."
            case .importFailed(let underlying): "The PDF could not be imported: \(underlying)"
            case .relinkMismatch: "That file is a different PDF from the one in the library."
            case .unreadableSource(let detail): "The PDF could not be read: \(detail)"
            }
        }
    }

    /// On-disk layout:
    /// ```
    /// rootDirectory/
    ///   index.json                  ← PDFLibraryIndexFile
    ///   {bookID}/
    ///     original.pdf              ← the live document; annotations are appended
    ///     cover.{ext}               ← optional
    ///   .staging/{UUID}/            ← atomic import staging
    /// ```
    public static let sourceFileName = "original.pdf"
    public static let indexFileName = "index.json"

    public let rootDirectory: URL
    private let parser: PDFDocumentParser
    private var index: PDFLibraryIndexFile
    private var bookCache: [String: ReaderBook] = [:]
    private var descriptorCache: [String: PDFDocumentDescriptor] = [:]
    private let cloudContainerIdentifier: String
    private let cloudRootOverride: URL?
    private var backgroundSyncTask: Task<Void, Never>?
    private var backgroundSyncRequested = false

    public init(
        rootDirectory: URL? = nil,
        parser: PDFDocumentParser = PDFDocumentParser(),
        cloudContainerIdentifier: String = ReaderICloudConfiguration.defaultContainerIdentifier
    ) {
        self.parser = parser
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootDirectory = base
                .appendingPathComponent("Amgi", isDirectory: true)
                .appendingPathComponent("PDFLibrary", isDirectory: true)
        }
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.cloudRootOverride = nil
        self.index = Self.readIndex(at: self.rootDirectory)
    }

    /// Test seam for a local directory standing in for the iCloud container.
    /// Production callers use the public initializer and the real container
    /// identifier.
    init(testingRootDirectory: URL, cloudRoot: URL) {
        self.rootDirectory = testingRootDirectory
        self.parser = PDFDocumentParser()
        self.cloudContainerIdentifier = ReaderICloudConfiguration.defaultContainerIdentifier
        self.cloudRootOverride = cloudRoot
        try? FileManager.default.createDirectory(
            at: testingRootDirectory,
            withIntermediateDirectories: true
        )
        self.index = Self.readIndex(at: testingRootDirectory)
    }

    // MARK: - Import

    /// Copies a PDF into the library and returns the book it became.
    ///
    /// Re-importing a file that is already present refreshes its metadata and
    /// leaves its annotations alone, because the ID is derived from a prefix of
    /// the file and the annotations live in the file itself. That is what makes
    /// "import the same PDF again" harmless rather than a way to lose work.
    @discardableResult
    public func importPDF(from sourceURL: URL) async throws -> ReaderBook {
        let needsScope = sourceURL.isFileURL && sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StoreError.importFailed(underlying: "The file no longer exists.")
        }

        let bookID: String
        do {
            bookID = try Self.deriveBookID(forFileAt: sourceURL)
        } catch {
            throw StoreError.importFailed(underlying: error.localizedDescription)
        }

        let existingID = Self.bookIDIfAlreadyPresent(candidateID: bookID, in: rootDirectory, index: index)

        // An import that would change the ID of a book already in the library
        // would silently create a second entry for the same document. This can
        // only happen if the two files share a prefix hash but differ, which is
        // vanishingly unlikely — so it is treated as a hard error rather than
        // allowed to produce a confusing library.
        if let existingID, existingID != bookID {
            throw StoreError.relinkMismatch(expected: existingID, found: bookID)
        }

        let finalDirectory = rootDirectory.appendingPathComponent(bookID, isDirectory: true)
        let stagingDirectory = rootDirectory
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let staged = stagingDirectory.appendingPathComponent(Self.sourceFileName)
            try fileManager.copyItem(at: sourceURL, to: staged)

            // Parse the staged copy. The managed book is not touched until this
            // succeeds, so a corrupt import cannot destroy a readable edition.
            let descriptor = try parser.parse(bytes: try Self.readBytes(at: staged), bookID: bookID)

            var coverRelative: String?
            if let cover = descriptor.coverImageData, !cover.isEmpty {
                let stagedCover = stagingDirectory.appendingPathComponent("cover.jpg")
                if (try? cover.write(to: stagedCover, options: .atomic)) != nil {
                    coverRelative = "\(bookID)/cover.jpg"
                }
                // A cover is optional; a document without one is still readable.
            }

            let now = nextSyncDate(after: index.entries.first { $0.bookID == bookID }?.syncDate)
            let book = makeBook(from: descriptor, sourceURL: finalDirectory)
            let chapterEntries = book.chapters.map {
                PDFLibraryIndexChapter(id: $0.id, title: $0.title, order: $0.order, pageCount: $0.pageCount)
            }
            let entry = PDFLibraryIndexEntry(
                bookID: bookID,
                title: descriptor.title,
                author: descriptor.author,
                coverRelativePath: coverRelative,
                language: descriptor.language,
                pageCount: descriptor.pageCount,
                chapters: chapterEntries,
                updatedAt: now
            )

            try commit(stagingDirectory, to: finalDirectory, fileManager: fileManager)
            let previousEntries = index.entries
            if let position = index.entries.firstIndex(where: { $0.bookID == bookID }) {
                index.entries[position] = entry
            } else {
                index.entries.append(entry)
            }
            do {
                try writeIndex()
            } catch {
                index.entries = previousEntries
                throw StoreError.importFailed(underlying: "The library index could not be written.")
            }

            bookCache[bookID] = book
            descriptorCache[bookID] = descriptor
            return book
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.importFailed(underlying: error.localizedDescription)
        }
    }

    /// Moves a staged directory into place, keeping the old one until the index
    /// has been written.
    ///
    /// The order matters: the file lands first, then the index names it. A crash
    /// between the two leaves an unreferenced directory, which is harmless, where
    /// the reverse order would leave the library pointing at nothing.
    private func commit(
        _ stagingDirectory: URL,
        to finalDirectory: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: finalDirectory.path) {
            let displaced = rootDirectory
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent("replaced-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: finalDirectory, to: displaced)
            defer { try? fileManager.removeItem(at: displaced) }
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        } else {
            try fileManager.createDirectory(
                at: finalDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        }
    }

    // MARK: - iCloud mirror

    /// Schedule a coalesced background upload of the local library. Cloud
    /// work must never make the library screen or reader wait on a provider.
    public func scheduleICloudSync() {
        guard backgroundSyncTask == nil else {
            backgroundSyncRequested = true
            return
        }
        backgroundSyncTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.synchronizeWithICloud()
            await self.finishScheduledICloudSync()
        }
    }

    private func finishScheduledICloudSync() {
        backgroundSyncTask = nil
        if backgroundSyncRequested {
            backgroundSyncRequested = false
            scheduleICloudSync()
        }
    }

    private func localEntrySourceURL(_ bookID: String) -> URL {
        rootDirectory
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent(Self.sourceFileName)
    }

    private func cloudMetadata(
        from local: PDFLibraryIndexEntry
    ) -> PDFCloudBookMetadata {
        PDFCloudBookMetadata(
            bookID: local.bookID,
            title: local.title,
            author: local.author,
            coverFileName: local.coverRelativePath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            },
            language: local.language,
            pageCount: local.pageCount,
            updatedAt: local.updatedAt
        )
    }

    private func uploadBook(
        localEntry: PDFLibraryIndexEntry,
        to cloudDirectory: URL
    ) async throws -> Bool {
        let sourceURL = localEntrySourceURL(localEntry.bookID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }
        try await PDFICloudStorage.replaceItem(
            at: sourceURL,
            with: cloudDirectory.appendingPathComponent(Self.sourceFileName)
        )

        if let relativeCover = localEntry.coverRelativePath {
            // The index is trusted storage, but a damaged index must not turn
            // into a path traversal: only accept paths that stay inside the
            // library root.
            let coverURL = rootDirectory.appendingPathComponent(relativeCover).standardizedFileURL
            let prefix = rootDirectory.standardizedFileURL.path + "/"
            if coverURL.path.hasPrefix(prefix),
               FileManager.default.fileExists(atPath: coverURL.path) {
                try await PDFICloudStorage.replaceItem(
                    at: coverURL,
                    with: cloudDirectory.appendingPathComponent(coverURL.lastPathComponent)
                )
            }
        }
        try await PDFICloudStorage.writeMetadata(
            cloudMetadata(from: localEntry),
            at: cloudDirectory
        )
        return true
    }

    /// Upload local books and their per-book metadata to the app-owned iCloud
    /// Drive container, then restore cloud-only books that are absent locally.
    /// There is no shared catalog and no cloud deletion propagation; local
    /// tombstones keep a deleted book deleted on the device that deleted it.
    public func synchronizeWithICloud() async -> PDFICloudSyncResult {
        guard let cloudLibraryURL = PDFICloudStorage.libraryURL(
            containerIdentifier: cloudContainerIdentifier,
            overrideRoot: cloudRootOverride
        ) else {
            return .unavailable
        }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: cloudLibraryURL.appendingPathComponent("books", isDirectory: true),
                withIntermediateDirectories: true
            )

            var uploadedBookIDs: [String] = []
            for entry in index.entries where !entry.isDeleted {
                guard let cloudDirectory = PDFICloudStorage.bookDirectory(
                    entry.bookID,
                    under: cloudLibraryURL
                ) else { continue }
                let cloudSource = cloudDirectory.appendingPathComponent(Self.sourceFileName)
                let metadata = cloudMetadata(from: entry)
                let alreadyMirrored: Bool
                if let existing = try? PDFICloudStorage.readMetadata(
                    at: cloudDirectory
                ), existing.bookID == entry.bookID,
                    existing.updatedAt == metadata.updatedAt {
                    alreadyMirrored = fileManager.fileExists(atPath: cloudSource.path)
                } else {
                    alreadyMirrored = false
                }
                guard !alreadyMirrored else { continue }

                if try await uploadBook(localEntry: entry, to: cloudDirectory) {
                    uploadedBookIDs.append(entry.bookID)
                }
            }

            // Cloud books are independent content-addressed entries rather
            // than a shared catalog. Restore only books absent from this local
            // index; a local tombstone intentionally wins forever on this
            // device, so deleting locally never resurrects a cloud backup.
            var restoredBookIDs: [String] = []
            var restoreFailure: (any Error)?
            let localBookIDs = Set(
                index.entries
                    .filter {
                        $0.isDeleted
                            || fileManager.fileExists(
                                atPath: localEntrySourceURL($0.bookID).path
                            )
                    }
                    .map(\.bookID)
            )
            let remoteBookIDs = try PDFICloudStorage.remoteBookIDs(in: cloudLibraryURL)
            for remoteBookID in remoteBookIDs where !localBookIDs.contains(remoteBookID) {
                do {
                    _ = try await restoreFromICloud(bookID: remoteBookID)
                    restoredBookIDs.append(remoteBookID)
                } catch {
                    restoreFailure = restoreFailure ?? error
                }
            }

            if let restoreFailure {
                return PDFICloudSyncResult(
                    status: .failed,
                    uploadedBookIDs: uploadedBookIDs.sorted(),
                    restoredBookIDs: restoredBookIDs.sorted(),
                    message: restoreFailure.localizedDescription
                )
            }
            return PDFICloudSyncResult(
                status: .completed,
                uploadedBookIDs: uploadedBookIDs.sorted(),
                restoredBookIDs: restoredBookIDs.sorted()
            )
        } catch {
            return PDFICloudSyncResult(
                status: .failed,
                message: error.localizedDescription
            )
        }
    }

    /// IDs of books currently visible in the iCloud backup, for a future
    /// explicit restore surface. Normal background sync restores additive
    /// entries while retaining local deletion tombstones.
    public func remoteBookIDs() async -> [String] {
        guard let cloudLibraryURL = PDFICloudStorage.libraryURL(
            containerIdentifier: cloudContainerIdentifier,
            overrideRoot: cloudRootOverride
        ) else { return [] }
        return (try? PDFICloudStorage.remoteBookIDs(in: cloudLibraryURL)) ?? []
    }

    /// Explicitly restore one cloud book through the same validated local
    /// import pipeline used for user-selected files.
    public func restoreFromICloud(bookID: String) async throws -> ReaderBook {
        guard let cloudLibraryURL = PDFICloudStorage.libraryURL(
            containerIdentifier: cloudContainerIdentifier,
            overrideRoot: cloudRootOverride
        ) else {
            throw PDFLibraryCloudError.sourceUnavailable
        }
        guard let cloudDirectory = PDFICloudStorage.bookDirectory(
            bookID,
            under: cloudLibraryURL
        ) else {
            throw PDFLibraryCloudError.invalidBookID
        }

        let cloudSource = cloudDirectory.appendingPathComponent(Self.sourceFileName)
        let metadata = (try? PDFICloudStorage.readMetadata(at: cloudDirectory))
            .flatMap { $0.bookID == bookID ? $0 : nil }
        guard FileManager.default.fileExists(atPath: cloudSource.path) else {
            throw PDFLibraryCloudError.bookNotFound
        }
        try await PDFICloudStorage.ensureDownloaded(at: cloudSource)
        let downloadedBookID = try Self.deriveBookID(forFileAt: cloudSource)
        guard downloadedBookID == bookID else {
            throw PDFLibraryCloudError.sourceUnavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiPDFCloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let localSource = temporaryDirectory.appendingPathComponent(Self.sourceFileName)
        try await PDFICloudStorage.replaceItem(at: cloudSource, with: localSource)
        let book = try await importPDF(from: localSource)
        guard book.id == bookID else {
            throw PDFLibraryCloudError.sourceUnavailable
        }
        if let metadata,
           let position = index.entries.firstIndex(where: { $0.bookID == bookID }) {
            var restoredEntry = index.entries[position]
            if let coverFileName = metadata.coverFileName,
               !coverFileName.contains("/"),
               !coverFileName.contains("\\"),
               coverFileName != ".",
               coverFileName != ".." {
                let cloudCover = cloudDirectory.appendingPathComponent(coverFileName)
                if FileManager.default.fileExists(atPath: cloudCover.path) {
                    do {
                        try await PDFICloudStorage.ensureDownloaded(at: cloudCover)
                        let localCover = rootDirectory
                            .appendingPathComponent(bookID, isDirectory: true)
                            .appendingPathComponent(coverFileName)
                        try await PDFICloudStorage.replaceItem(
                            at: cloudCover,
                            with: localCover
                        )
                        restoredEntry.coverRelativePath = "\(bookID)/\(coverFileName)"
                    } catch {
                        // Covers are optional; the document remains readable with
                        // whatever the local parser extracted — or the first-page
                        // thumbnail the library falls back to.
                    }
                }
            }
            restoredEntry.title = metadata.title
            restoredEntry.author = metadata.author
            restoredEntry.language = metadata.language
            restoredEntry.pageCount = metadata.pageCount
            restoredEntry.updatedAt = metadata.updatedAt
            restoredEntry.deletedAt = nil
            index.entries[position] = restoredEntry
            try writeIndex()
        }
        return book
    }

    // MARK: - Reading

    public func books() async -> [ReaderBook] {
        var out: [ReaderBook] = []
        for entry in index.entries where !entry.isDeleted {
            if let cached = bookCache[entry.bookID] {
                out.append(cached)
                continue
            }
            if entry.fault != nil {
                out.append(Self.placeholderBook(for: entry))
                continue
            }
            let source = rootDirectory
                .appendingPathComponent(entry.bookID, isDirectory: true)
                .appendingPathComponent(Self.sourceFileName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                record(
                    fault: .sourceMissing,
                    detail: "The PDF is no longer in the library folder.",
                    for: entry.bookID
                )
                out.append(Self.placeholderBook(for: entry))
                continue
            }
            let book = makeBook(from: entry)
            out.append(book)
        }
        return out
    }

    /// Retrieves a fully parsed ReaderBook on demand, re-parsing and caching chapters if uncached.
    public func book(bookID: String) async -> ReaderBook? {
        if let cached = bookCache[bookID] { return cached }
        guard let position = index.entries.firstIndex(where: { $0.bookID == bookID && !$0.isDeleted }) else {
            return nil
        }
        let entry = index.entries[position]
        let outcome = await rebuildBook(from: entry)
        if let book = outcome.book {
            bookCache[bookID] = book
            if index.entries[position].chapters == nil {
                index.entries[position].chapters = book.chapters.map {
                    PDFLibraryIndexChapter(id: $0.id, title: $0.title, order: $0.order, pageCount: $0.pageCount)
                }
                try? writeIndex()
            }
            return book
        }
        return nil
    }

    /// Current repair state for every non-deleted book, keyed by book ID.
    ///
    /// Verifies source file presence per book without re-reading bytes or re-parsing,
    /// so missing files are reported immediately without stalling app launch.
    public func bookHealth() async -> [String: PDFLibraryBookHealth] {
        var out: [String: PDFLibraryBookHealth] = [:]
        let fileManager = FileManager.default
        for entry in index.entries where !entry.isDeleted {
            let source = rootDirectory
                .appendingPathComponent(entry.bookID, isDirectory: true)
                .appendingPathComponent(Self.sourceFileName)
            if !fileManager.fileExists(atPath: source.path) {
                record(
                    fault: .sourceMissing,
                    detail: "The PDF is no longer in the library folder.",
                    for: entry.bookID
                )
            }
            let current = index.entries.first { $0.bookID == entry.bookID } ?? entry
            out[entry.bookID] = Self.health(for: current)
        }
        return out
    }

    /// Clears a fault and re-reads one book. Returns the recovered book, or nil
    /// if the source is still unusable.
    @discardableResult
    public func retryBook(bookID: String) async -> ReaderBook? {
        guard let position = index.entries.firstIndex(where: { $0.bookID == bookID }) else {
            return nil
        }
        index.entries[position].fault = nil
        index.entries[position].faultDetail = nil
        bookCache[bookID] = nil
        descriptorCache[bookID] = nil
        let outcome = await rebuildBook(from: index.entries[position])
        if let book = outcome.book {
            bookCache[bookID] = book
        }
        return outcome.book
    }

    /// Points a book at a replacement file on disk.
    ///
    /// The replacement must be the same document: a different PDF would give a
    /// different ID, and accepting it would leave the library showing one book's
    /// metadata over another's pages — with the old annotations still in the old
    /// file, unreachable.
    @discardableResult
    public func relinkBook(bookID: String, to replacementURL: URL) async throws -> ReaderBook {
        guard let position = index.entries.firstIndex(where: { $0.bookID == bookID }) else {
            throw StoreError.bookNotFound
        }
        let replacementID: String
        do {
            replacementID = try Self.deriveBookID(forFileAt: replacementURL)
        } catch {
            throw StoreError.importFailed(underlying: error.localizedDescription)
        }
        guard replacementID == bookID else {
            throw StoreError.relinkMismatch(expected: bookID, found: replacementID)
        }

        let needsScope = replacementURL.isFileURL
            && replacementURL.startAccessingSecurityScopedResource()
        defer { if needsScope { replacementURL.stopAccessingSecurityScopedResource() } }

        let directory = rootDirectory.appendingPathComponent(bookID, isDirectory: true)
        let destination = directory.appendingPathComponent(Self.sourceFileName)
        let fileManager = FileManager.default
        // A relink replaces the document, so the previous one is moved aside
        // rather than overwritten: the old file's annotations are real work, and
        // a failed relink should not have destroyed them.
        let backup = directory.appendingPathComponent("replaced-\(UUID().uuidString).pdf")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.copyItem(at: replacementURL, to: destination)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw StoreError.importFailed(underlying: error.localizedDescription)
        }
        try? fileManager.removeItem(at: backup)

        bookCache[bookID] = nil
        descriptorCache[bookID] = nil
        index.entries[position].fault = nil
        index.entries[position].faultDetail = nil
        let outcome = await rebuildBook(from: index.entries[position])
        guard let book = outcome.book else {
            throw StoreError.unreadableSource(
                index.entries[position].faultDetail ?? "The file could not be read."
            )
        }
        bookCache[bookID] = book
        return book
    }

    // MARK: - Deleting

    /// Removes a book from the library, keeping a tombstone.
    ///
    /// The file is left on disk. A tombstone rather than a deletion is what
    /// stops a later sync from restoring a book the user removed on this
    /// device, and it costs a directory that can be swept later.
    public func delete(bookID: String) async throws {
        guard let position = index.entries.firstIndex(where: { $0.bookID == bookID }) else {
            throw StoreError.bookNotFound
        }
        index.entries[position].deletedAt = Date()
        index.entries[position].updatedAt = Date()
        try writeIndex()
        bookCache[bookID] = nil
        descriptorCache[bookID] = nil
    }

    // MARK: - Annotation surface

    /// The managed file for a book.
    public func sourceURL(bookID: String) -> URL? {
        guard let entry = index.entries.first(where: { $0.bookID == bookID }), !entry.isDeleted
        else { return nil }
        let url = rootDirectory
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent(Self.sourceFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The full parsed descriptor, for the reader.
    public func descriptor(bookID: String) async -> PDFDocumentDescriptor? {
        if let cached = descriptorCache[bookID] { return cached }
        guard let entry = index.entries.first(where: { $0.bookID == bookID }), !entry.isDeleted
        else { return nil }
        let outcome = await rebuildBook(from: entry)
        return outcome.descriptor
    }

    /// Appends bytes to a book's file and returns the new contents.
    ///
    /// The only write path for annotations, and it exists so the append and the
    /// subsequent reload cannot be reordered against each other by a caller.
    /// Reloading matters: the descriptor's annotation-free view is cheap, but the
    /// file on disk is what every other reader — Preview, Mail, a second device
    /// — will see, and it must be the file, not a copy held in memory.
    @discardableResult
    public func append(to bookID: String, update: [UInt8]) async throws -> [UInt8] {
        guard let url = sourceURL(bookID: bookID) else { throw StoreError.bookNotFound }
        var bytes = try Self.readBytes(at: url)
        bytes.append(contentsOf: update)
        // Written through a temporary file and swapped, so an interrupted write
        // cannot leave a half-appended file. A PDF's incremental update is
        // already crash-safe at the section level, but a torn *file* is not, and
        // the file is the only copy.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".append-\(UUID().uuidString)")
        try Data(bytes).write(to: temporary, options: .atomic)
        let fileManager = FileManager.default
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        // Annotations live in the file itself, so an edit changes what the
        // next iCloud upload must carry. Bumping the timestamp is what marks
        // the book dirty for the mirror; without it an annotated file would
        // look already-mirrored forever.
        if let position = index.entries.firstIndex(where: { $0.bookID == bookID }) {
            index.entries[position].updatedAt = nextSyncDate(after: index.entries[position].updatedAt)
            try? writeIndex()
        }
        return bytes
    }

    /// Re-reads a book's file and refreshes its cached descriptor.
    @discardableResult
    public func reload(bookID: String) async throws -> PDFDocumentDescriptor {
        guard let url = sourceURL(bookID: bookID) else { throw StoreError.bookNotFound }
        let bytes = try Self.readBytes(at: url)
        let descriptor = try parser.parse(bytes: bytes, bookID: bookID)
        descriptorCache[bookID] = descriptor
        bookCache[bookID] = makeBook(from: descriptor, sourceURL: url.deletingLastPathComponent())
        if let position = index.entries.firstIndex(where: { $0.bookID == bookID }) {
            index.entries[position].pageCount = descriptor.pageCount
            index.entries[position].title = descriptor.title
            index.entries[position].author = descriptor.author
            index.entries[position].fault = nil
            index.entries[position].faultDetail = nil
            index.entries[position].updatedAt = nextSyncDate(after: index.entries[position].updatedAt)
            try? writeIndex()
        }
        return descriptor
    }

    // MARK: - Identity

    /// A stable identifier for a PDF file.
    ///
    /// The whole file cannot be hashed. Annotations are appended to the managed
    /// copy, so a whole-file hash changes the first time the user highlights
    /// something — and re-importing their own annotated PDF would then create a
    /// second library entry, with the annotations stranded in the first.
    ///
    /// A *prefix* hash looks like the fix and is not one, for a reason worth
    /// writing down: appending grows the file, so a prefix of "up to 64 KB"
    /// grows too, and for any document smaller than 64 KB the hash changes
    /// anyway. The test that pins this property uses a 615-byte fixture, which is
    /// exactly the case that exposes it.
    ///
    /// What is actually stable is the document's own `/ID`: the specification
    /// requires its first element to identify the original document and to be
    /// carried unchanged through every incremental update, which is precisely
    /// the guarantee needed here. So the `/ID` is used when the document has one,
    /// and a prefix hash is only the fallback for a document that does not.
    ///
    /// The fallback's limitation is real and is not papered over: an `/ID`-less
    /// document's identity changes once, the first time it is annotated, and is
    /// stable from then on because our writer gives it an `/ID`. The library
    /// never re-derives a book's ID, so the entry the user sees is unaffected;
    /// the only consequence is that re-importing such a file from outside would
    /// add a second entry rather than matching the first.
    public static func deriveBookID(forFileAt url: URL) throws -> String {
        let bytes = try readBytes(at: url)
        guard !bytes.isEmpty else {
            throw StoreError.importFailed(underlying: "The file is empty.")
        }
        if let file = try? PDFAppendableFile(bytes: bytes),
           let identifier = file.fileIdentifier,
           !identifier.isEmpty {
            return "pdf-" + digest(identifier)
        }
        // 64 KB is far more than any header and far less than a large document.
        return "pdf-" + digest(bytes[0..<min(bytes.count, 64 * 1_024)])
    }

    private static func digest(_ material: some Collection<UInt8>) -> String {
        SHA256.hash(data: Data(material)).map { String(format: "%02x", $0) }.joined()
    }

    /// The ID of `candidateID` if the library already holds that exact document.
    ///
    /// Compares derived IDs rather than raw bytes, because a managed file is
    /// annotated in place and so no longer matches the file the user picked
    /// byte-for-byte even though it is the same document.
    private static func bookIDIfAlreadyPresent(
        candidateID: String,
        in root: URL,
        index: PDFLibraryIndexFile
    ) -> String? {
        // Fast path: if the document is already present in the in-memory index or
        // its managed directory already exists, return immediately without
        // scanning and hashing every PDF in the library.
        if index.entries.contains(where: { $0.bookID == candidateID && !$0.isDeleted }) {
            return candidateID
        }
        let directFolder = root.appendingPathComponent(candidateID, isDirectory: true)
        if FileManager.default.fileExists(atPath: directFolder.appendingPathComponent(Self.sourceFileName).path) {
            return candidateID
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }

        return entries
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
            .map { $0.appendingPathComponent(Self.sourceFileName) }
            .first { existing in
                (try? deriveBookID(forFileAt: existing)) == candidateID
            }
            .flatMap { existing in
                // A derived ID is not a directory name to be trusted blindly; the
                // directory that actually holds this source is the answer.
                existing.deletingLastPathComponent().lastPathComponent
            }
    }

    // MARK: - Index

    private func nextSyncDate(after date: Date?) -> Date {
        let now = Date()
        // Strictly monotonic, so two writes in the same clock tick cannot look
        // simultaneous to a sync deciding which side is newer.
        if let date, date >= now { return date.addingTimeInterval(0.001) }
        return now
    }

    private func writeIndex() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let url = rootDirectory.appendingPathComponent(Self.indexFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: .atomic)
    }

    private static func readIndex(at root: URL) -> PDFLibraryIndexFile {
        let url = root.appendingPathComponent(indexFileName)
        guard let data = try? Data(contentsOf: url) else {
            // Missing, not merely unreadable. A brand-new library has no index
            // and legitimately has no books, so this cannot simply return empty:
            // an index deleted or lost with the device would then present as an
            // empty library while every imported PDF is still on disk. The user
            // sees their books gone and has no way to tell that they are not.
            return reconstructIndex(at: root)
        }
        let decoder = JSONDecoder()
        // Must match the encoder exactly. A mismatch here does not throw — it
        // silently reads every timestamp as seconds since 2001, which then makes
        // "later edit wins" comparisons in sync meaningless.
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(PDFLibraryIndexFile.self, from: data))
            ?? reconstructIndex(at: root)
    }

    /// Rebuilds an index by looking at the library directory.
    ///
    /// Reached when `index.json` is missing or unreadable. Without it the
    /// library would appear empty, and the user's imported books would still be
    /// sitting on disk — a failure that reads as data loss and is not.
    private static func reconstructIndex(at root: URL) -> PDFLibraryIndexFile {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return PDFLibraryIndexFile() }
        var entries: [PDFLibraryIndexEntry] = []
        for directory in directories where directory.hasDirectoryPath {
            let name = directory.lastPathComponent
            if name.hasPrefix(".") { continue }
            let source = directory.appendingPathComponent(sourceFileName)
            guard let data = try? Data(contentsOf: source) else { continue }
            let bookID = (try? deriveBookID(forFileAt: source)) ?? name
            let descriptor = try? PDFDocumentParser().parse(bytes: [UInt8](data), bookID: bookID)
            entries.append(PDFLibraryIndexEntry(
                bookID: bookID,
                title: descriptor?.title ?? name,
                author: descriptor?.author,
                coverRelativePath: nil,
                language: descriptor?.language,
                pageCount: descriptor?.pageCount ?? 0,
                updatedAt: (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            ))
        }
        return PDFLibraryIndexFile(entries: entries)
    }

    // MARK: - Rebuilding

    private struct RebuildOutcome {
        var book: ReaderBook?
        var descriptor: PDFDocumentDescriptor?
    }

    private func rebuildBook(from entry: PDFLibraryIndexEntry) async -> RebuildOutcome {
        let directory = rootDirectory.appendingPathComponent(entry.bookID, isDirectory: true)
        let source = directory.appendingPathComponent(Self.sourceFileName)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            record(fault: .sourceMissing, detail: "The PDF is no longer in the library folder.", for: entry.bookID)
            return RebuildOutcome(book: nil, descriptor: nil)
        }
        let bytes: [UInt8]
        do {
            bytes = try Self.readBytes(at: source)
        } catch {
            record(
                fault: .sourceUnreadable,
                detail: error.localizedDescription,
                for: entry.bookID
            )
            return RebuildOutcome(book: nil, descriptor: nil)
        }
        do {
            let descriptor = try parser.parse(bytes: bytes, bookID: entry.bookID)
            clearFault(for: entry.bookID)
            descriptorCache[entry.bookID] = descriptor
            return RebuildOutcome(
                book: makeBook(from: descriptor, sourceURL: directory),
                descriptor: descriptor
            )
        } catch let error as PDFDocumentParser.ParseError {
            // An encrypted PDF is a different situation from a broken one: it
            // opens in Preview and it can be read, it just cannot be
            // annotated. Recording it as `parseFailed` would offer a repair
            // action that cannot possibly help.
            let fault: PDFLibraryEntryFault = (error == .encrypted) ? .encrypted : .parseFailed
            record(fault: fault, detail: error.errorDescription, for: entry.bookID)
            return RebuildOutcome(book: nil, descriptor: nil)
        } catch {
            record(fault: .parseFailed, detail: error.localizedDescription, for: entry.bookID)
            return RebuildOutcome(book: nil, descriptor: nil)
        }
    }

    private func record(fault: PDFLibraryEntryFault, detail: String?, for bookID: String) {
        guard let position = index.entries.firstIndex(where: { $0.bookID == bookID }) else { return }
        // A fault that has not changed is not re-persisted, so listing the
        // library does not churn the index file on every launch.
        guard index.entries[position].fault != fault
            || index.entries[position].faultDetail != detail
        else { return }
        index.entries[position].fault = fault
        index.entries[position].faultDetail = detail
        try? writeIndex()
    }

    private func clearFault(for bookID: String) {
        guard let position = index.entries.firstIndex(where: { $0.bookID == bookID }),
              index.entries[position].fault != nil
        else { return }
        index.entries[position].fault = nil
        index.entries[position].faultDetail = nil
        try? writeIndex()
    }

    private static func health(for entry: PDFLibraryIndexEntry) -> PDFLibraryBookHealth {
        if let fault = entry.fault {
            return PDFLibraryBookHealth(
                bookID: entry.bookID,
                state: .needsRepair(fault: fault, detail: entry.faultDetail)
            )
        }
        return PDFLibraryBookHealth(bookID: entry.bookID, state: .ready)
    }

    private static func placeholderBook(for entry: PDFLibraryIndexEntry) -> ReaderBook {
        // Carries the title and fault so the library row is recognisable and
        // can offer the repair action, rather than a row that vanished.
        ReaderBook(
            id: entry.bookID,
            title: entry.title,
            author: entry.author,
            coverImagePath: entry.coverRelativePath,
            language: entry.language,
            chapters: [],
            pageCount: entry.pageCount,
            source: .pdf(localURL: URL(fileURLWithPath: "/dev/null"))
        )
    }

    private func makeBook(from entry: PDFLibraryIndexEntry) -> ReaderBook {
        let directory = rootDirectory.appendingPathComponent(entry.bookID, isDirectory: true)
        let file = directory.appendingPathComponent(Self.sourceFileName)
        let coverPath = entry.coverRelativePath.flatMap { relative -> String? in
            let url = rootDirectory.appendingPathComponent(relative).standardizedFileURL
            let prefix = rootDirectory.standardizedFileURL.path + "/"
            return url.path.hasPrefix(prefix) ? url.path : nil
        }
        let chapters = entry.chapters?.map {
            ReaderChapter(
                id: $0.id,
                bookID: entry.bookID,
                bookTitle: entry.title,
                title: $0.title,
                order: $0.order,
                content: "",
                language: entry.language,
                pageCount: $0.pageCount
            )
        } ?? []
        return ReaderBook(
            id: entry.bookID,
            title: entry.title,
            author: entry.author,
            coverImagePath: coverPath,
            language: entry.language,
            chapters: chapters,
            pageCount: entry.pageCount,
            source: .pdf(localURL: file)
        )
    }

    /// Turns a descriptor into the library's book model.
    ///
    /// A PDF is already paginated, so there is no pagination index to build the
    /// way an EPUB needs one. Chapters come from the document outline, because
    /// that is what the reader's chapter list means for a PDF; a document with
    /// no outline gets a single chapter covering the whole document, so the
    /// detail view has something to show rather than an empty section.
    private func makeBook(
        from descriptor: PDFDocumentDescriptor,
        sourceURL directory: URL
    ) -> ReaderBook {
        let file = directory.appendingPathComponent(Self.sourceFileName)
        let chapters: [ReaderChapter]
        if descriptor.outline.isEmpty {
            // A document with no outline still needs something in the chapter
            // list, so it gets one chapter covering the whole document starting
            // at page 0. An empty section in the detail view would read as a
            // bug rather than as "this PDF has no table of contents".
            chapters = [ReaderChapter(
                id: ReaderChapter.pdfChapterID(
                    bookID: descriptor.bookID,
                    outlineID: PDFOutlineEntry.outlineID(path: [0])
                ),
                bookID: descriptor.bookID,
                bookTitle: descriptor.title,
                title: descriptor.title,
                order: String(format: "%08d", 0),
                content: "",
                language: descriptor.language,
                pageCount: descriptor.pageCount
            )]
        } else {
            chapters = descriptor.outline.map { entry in
                ReaderChapter(
                    id: ReaderChapter.pdfChapterID(bookID: descriptor.bookID, outlineID: entry.id),
                    bookID: descriptor.bookID,
                    bookTitle: descriptor.title,
                    title: entry.title,
                    order: String(format: "%08d", entry.pageIndex),
                    content: "",
                    language: descriptor.language,
                    pageCount: nil
                )
            }
        }
        return ReaderBook(
            id: descriptor.bookID,
            title: descriptor.title,
            author: descriptor.author,
            coverImagePath: nil,
            language: descriptor.language,
            chapters: chapters,
            pageCount: descriptor.pageCount,
            source: .pdf(localURL: file)
        )
    }

    private static func readBytes(at url: URL) throws -> [UInt8] {
        do {
            return [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            throw StoreError.unreadableSource(error.localizedDescription)
        }
    }
}
