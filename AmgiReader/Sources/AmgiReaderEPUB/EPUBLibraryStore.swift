public import Foundation
public import AmgiReader

/// Actor-owned on-disk library of imported EPUB books.
///
/// Layout under `rootDirectory`:
/// ```
/// index.json
/// {bookID}/
///   original.epub
///   original/ ...         (EPUBKit extraction, created during parse)
///   cover.{ext}
/// ```
///
/// The iCloud Drive backup mirror lives at
/// `<container>/Documents/EPUB/books/{bookID}/original.epub` with a
/// per-book `metadata.json`; cloud-only books are restored additively, while
/// extraction directories remain local because they are disposable parser
/// caches.
///
/// `books()` rebuilds `ReaderBook` values from the index plus the on-disk
/// extracted chapter URLs, without re-running the full EPUB parse each
/// time. Parsed books are cached in-memory between calls.
public actor EPUBLibraryStore {

    public enum StoreError: Error, Sendable {
        case bookNotFound
        case missingExtractedDirectory
        case importFailed(underlying: String)
    }

    private let rootDirectory: URL
    private let cloudContainerIdentifier: String
    private let cloudRootOverride: URL?
    private var index: EPUBLibraryIndexFile
    private var bookCache: [String: ReaderBook] = [:]
    private var chapterURLCache: [String: [Int64: URL]] = [:]
    private var contentRootCache: [String: URL] = [:]
    private var backgroundSyncTask: Task<Void, Never>?
    private var backgroundSyncRequested = false
    private let parser = EPUBBookParser()

    public init(
        rootDirectory: URL? = nil,
        cloudContainerIdentifier: String = EPUBICloudConfiguration.defaultContainerIdentifier
    ) {
        let root: URL
        if let rootDirectory {
            root = rootDirectory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            root = support.appendingPathComponent("Amgi/EPUBLibrary", isDirectory: true)
        }
        self.init(
            rootDirectory: root,
            cloudRootOverride: nil,
            cloudContainerIdentifier: cloudContainerIdentifier
        )
    }

    /// Test seam for a local directory standing in for the iCloud container.
    /// Production callers use the public initializer and the real container
    /// identifier.
    init(testingRootDirectory: URL, cloudRoot: URL) {
        self.init(
            rootDirectory: testingRootDirectory,
            cloudRootOverride: cloudRoot,
            cloudContainerIdentifier: EPUBICloudConfiguration.defaultContainerIdentifier
        )
    }

    private init(
        rootDirectory: URL,
        cloudRootOverride: URL?,
        cloudContainerIdentifier: String
    ) {
        self.rootDirectory = rootDirectory
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.cloudRootOverride = cloudRootOverride
        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        self.index = Self.readIndex(at: rootDirectory) ?? EPUBLibraryIndexFile()
    }

    // MARK: - Public API

    public func importEPUB(from sourceURL: URL) async throws -> ReaderBook {
        let needsScope = sourceURL.isFileURL && sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let bookID: String
        do {
            bookID = try EPUBBookParser.deriveBookID(forFileAt: sourceURL)
        } catch {
            throw StoreError.importFailed(underlying: error.localizedDescription)
        }

        let fileManager = FileManager.default
        let finalBookDirectory = rootDirectory.appendingPathComponent(bookID, isDirectory: true)
        let stagingParent = rootDirectory.appendingPathComponent(".staging", isDirectory: true)
        let stagingDirectory = stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let stagedEPUB = stagingDirectory.appendingPathComponent("original.epub")
            try fileManager.copyItem(at: sourceURL, to: stagedEPUB)

            // Parse the staged copy. The existing managed book is not touched
            // until this succeeds, so a corrupt re-import cannot destroy a
            // previously readable edition.
            let stagedBook = try await parser.parse(fileURL: stagedEPUB)

            var coverRelative: String?
            if let coverURL = stagedBook.coverImageURL,
               fileManager.fileExists(atPath: coverURL.path) {
                let ext = coverURL.pathExtension.isEmpty ? "img" : coverURL.pathExtension
                let stagedCover = stagingDirectory.appendingPathComponent("cover.\(ext)")
                do {
                    if fileManager.fileExists(atPath: stagedCover.path) {
                        try fileManager.removeItem(at: stagedCover)
                    }
                    try fileManager.copyItem(at: coverURL, to: stagedCover)
                    coverRelative = "\(bookID)/cover.\(ext)"
                } catch {
                    // A cover is optional; keep the import usable without one.
                    coverRelative = nil
                }
            }

            // EPUBKit returns absolute URLs into its extraction directory.
            // Rebase them before moving the staged directory into the library
            // so the live ReaderBook never points at a temporary path.
            let committedBook = rebase(
                stagedBook,
                from: stagingDirectory,
                to: finalBookDirectory
            )
            let now = nextSyncDate(after: index.entries.first(where: { $0.bookID == bookID })?.syncDate)
            let entry = EPUBLibraryIndexEntry(
                bookID: bookID,
                title: committedBook.book.title,
                author: committedBook.book.author,
                coverRelativePath: coverRelative,
                language: committedBook.language,
                pageCount: committedBook.pageCount,
                updatedAt: now
            )

            let backupDirectory = try replaceBookDirectory(
                stagingDirectory,
                with: finalBookDirectory
            )

            let previousEntries = index.entries
            if let existing = index.entries.firstIndex(where: { $0.bookID == bookID }) {
                index.entries[existing] = entry
            } else {
                index.entries.append(entry)
            }
            do {
                try writeIndex()
            } catch {
                index.entries = previousEntries
                try? fileManager.removeItem(at: finalBookDirectory)
                if let backupDirectory {
                    try? fileManager.moveItem(at: backupDirectory, to: finalBookDirectory)
                }
                throw StoreError.importFailed(underlying: String(describing: error))
            }

            if let backupDirectory {
                try? fileManager.removeItem(at: backupDirectory)
            }

            bookCache[bookID] = committedBook.book
            chapterURLCache[bookID] = committedBook.chapterContentURLs
            contentRootCache[bookID] = committedBook.contentDirectory
            return committedBook.book
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.importFailed(underlying: String(describing: error))
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

    private func nextSyncDate(after previous: Date?) -> Date {
        let now = Date.now
        guard let previous else { return now }
        return max(now, previous.addingTimeInterval(0.001))
    }

    private func localEntrySourceURL(_ bookID: String) -> URL {
        rootDirectory
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent("original.epub")
    }

    private func localURL(forRelativePath relativePath: String) -> URL? {
        let rootPath = rootDirectory.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let url = rootDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(prefix) else { return nil }
        return url
    }

    private func cloudMetadata(
        from local: EPUBLibraryIndexEntry
    ) -> EPUBCloudBookMetadata {
        EPUBCloudBookMetadata(
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
        localEntry: EPUBLibraryIndexEntry,
        to cloudDirectory: URL
    ) async throws -> Bool {
        let sourceURL = localEntrySourceURL(localEntry.bookID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }
        try await EPUBICloudStorage.replaceItem(
            at: sourceURL,
            with: cloudDirectory.appendingPathComponent("original.epub")
        )

        if let relativeCover = localEntry.coverRelativePath,
           let coverURL = localURL(forRelativePath: relativeCover),
           FileManager.default.fileExists(atPath: coverURL.path) {
            try await EPUBICloudStorage.replaceItem(
                at: coverURL,
                with: cloudDirectory.appendingPathComponent(coverURL.lastPathComponent)
            )
        }
        try await EPUBICloudStorage.writeMetadata(
            cloudMetadata(from: localEntry),
            at: cloudDirectory
        )
        return true
    }

    /// Upload local books and their per-book metadata to the app-owned iCloud
    /// Drive container, then restore cloud-only books that are absent locally.
    /// There is no shared catalog and no cloud deletion propagation; local
    /// tombstones keep a deleted book deleted on the device that deleted it.
    public func synchronizeWithICloud() async -> EPUBICloudSyncResult {
        guard let cloudLibraryURL = EPUBICloudStorage.libraryURL(
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
                guard let cloudDirectory = EPUBICloudStorage.bookDirectory(
                    entry.bookID,
                    under: cloudLibraryURL
                ) else { continue }
                let cloudSource = cloudDirectory.appendingPathComponent("original.epub")
                let metadata = cloudMetadata(from: entry)
                let alreadyMirrored: Bool
                if let existing = try? EPUBICloudStorage.readMetadata(
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
            let remoteBookIDs = try EPUBICloudStorage.remoteBookIDs(in: cloudLibraryURL)
            for remoteBookID in remoteBookIDs where !localBookIDs.contains(remoteBookID) {
                do {
                    _ = try await restoreFromICloud(bookID: remoteBookID)
                    restoredBookIDs.append(remoteBookID)
                } catch {
                    restoreFailure = restoreFailure ?? error
                }
            }

            if let restoreFailure {
                return EPUBICloudSyncResult(
                    status: .failed,
                    uploadedBookIDs: uploadedBookIDs.sorted(),
                    restoredBookIDs: restoredBookIDs.sorted(),
                    message: restoreFailure.localizedDescription
                )
            }
            return EPUBICloudSyncResult(
                status: .completed,
                uploadedBookIDs: uploadedBookIDs.sorted(),
                restoredBookIDs: restoredBookIDs.sorted()
            )
        } catch {
            return EPUBICloudSyncResult(
                status: .failed,
                message: error.localizedDescription
            )
        }
    }

    /// IDs of books currently visible in the iCloud backup, for a future
    /// explicit restore surface. Normal background sync restores additive
    /// entries while retaining local deletion tombstones.
    public func remoteBookIDs() async -> [String] {
        guard let cloudLibraryURL = EPUBICloudStorage.libraryURL(
            containerIdentifier: cloudContainerIdentifier,
            overrideRoot: cloudRootOverride
        ) else { return [] }
        return (try? EPUBICloudStorage.remoteBookIDs(in: cloudLibraryURL)) ?? []
    }

    /// Explicitly restore one cloud book through the same validated local
    /// import pipeline used for user-selected files.
    public func restoreFromICloud(bookID: String) async throws -> ReaderBook {
        guard let cloudLibraryURL = EPUBICloudStorage.libraryURL(
            containerIdentifier: cloudContainerIdentifier,
            overrideRoot: cloudRootOverride
        ) else {
            throw EPUBLibraryCloudError.sourceUnavailable
        }
        guard let cloudDirectory = EPUBICloudStorage.bookDirectory(
            bookID,
            under: cloudLibraryURL
        ) else {
            throw EPUBLibraryCloudError.invalidBookID
        }

        let cloudSource = cloudDirectory.appendingPathComponent("original.epub")
        let metadata = (try? EPUBICloudStorage.readMetadata(at: cloudDirectory))
            .flatMap { $0.bookID == bookID ? $0 : nil }
        guard FileManager.default.fileExists(atPath: cloudSource.path) else {
            throw EPUBLibraryCloudError.bookNotFound
        }
        try await EPUBICloudStorage.ensureDownloaded(at: cloudSource)
        let downloadedBookID = try EPUBBookParser.deriveBookID(forFileAt: cloudSource)
        guard downloadedBookID == bookID else {
            throw EPUBLibraryCloudError.sourceUnavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiEPUCloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let localSource = temporaryDirectory.appendingPathComponent("original.epub")
        try await EPUBICloudStorage.replaceItem(at: cloudSource, with: localSource)
        let book = try await importEPUB(from: localSource)
        guard book.id == bookID else {
            throw EPUBLibraryCloudError.sourceUnavailable
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
                        try await EPUBICloudStorage.ensureDownloaded(at: cloudCover)
                        let localCover = rootDirectory
                            .appendingPathComponent(bookID, isDirectory: true)
                            .appendingPathComponent(coverFileName)
                        try await EPUBICloudStorage.replaceItem(
                            at: cloudCover,
                            with: localCover
                        )
                        restoredEntry.coverRelativePath = "\(bookID)/\(coverFileName)"
                    } catch {
                        // Covers are optional; the EPUB remains readable with
                        // whatever cover the local parser extracted.
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

    public func books() async -> [ReaderBook] {
        var out: [ReaderBook] = []
        for entry in index.entries where !entry.isDeleted {
            if let cached = bookCache[entry.bookID] {
                out.append(cached)
                continue
            }
            if let rebuilt = await rebuildBook(from: entry) {
                bookCache[entry.bookID] = rebuilt
                out.append(rebuilt)
            }
        }
        return out
    }

    public func delete(bookID: String) async throws {
        guard let idx = index.entries.firstIndex(where: { $0.bookID == bookID }) else {
            throw StoreError.bookNotFound
        }
        let bookDir = rootDirectory.appendingPathComponent(bookID, isDirectory: true)
        try? FileManager.default.removeItem(at: bookDir)
        let now = nextSyncDate(after: index.entries[idx].syncDate)
        index.entries[idx].updatedAt = now
        index.entries[idx].deletedAt = now
        index.entries[idx].coverRelativePath = nil
        bookCache.removeValue(forKey: bookID)
        chapterURLCache.removeValue(forKey: bookID)
        contentRootCache.removeValue(forKey: bookID)
        try writeIndex()
    }

    public func contentURL(bookID: String, chapterID: Int64) async -> URL? {
        if let map = chapterURLCache[bookID], let url = map[chapterID] {
            return url
        }
        guard let entry = index.entries.first(where: { $0.bookID == bookID && !$0.isDeleted }) else { return nil }
        _ = await rebuildBook(from: entry)
        return chapterURLCache[bookID]?[chapterID]
    }

    /// The book's content root (the OPF directory). WebViews are granted
    /// read access to this rather than to the chapter file's own parent, so
    /// a chapter in `OEBPS/Text/` can still load `OEBPS/Styles/` and
    /// `OEBPS/Images/`.
    public func contentRootURL(bookID: String) async -> URL? {
        if let root = contentRootCache[bookID] { return root }
        guard let entry = index.entries.first(where: { $0.bookID == bookID && !$0.isDeleted }) else { return nil }
        _ = await rebuildBook(from: entry)
        return contentRootCache[bookID]
    }

    public func coverURL(bookID: String) async -> URL? {
        guard let entry = index.entries.first(where: { $0.bookID == bookID && !$0.isDeleted }),
              let rel = entry.coverRelativePath else { return nil }
        guard let url = localURL(forRelativePath: rel) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Internals

    /// Rebase all parser-produced URLs after a staged extraction is moved to
    /// its managed library location. EPUBKit intentionally exposes absolute
    /// URLs, so leaving them untouched would make a successfully imported
    /// book point into `.staging` after the commit.
    private func rebase(
        _ parsed: ParsedEPUBBook,
        from sourceRoot: URL,
        to destinationRoot: URL
    ) -> ParsedEPUBBook {
        var result = parsed
        let sourcePath = sourceRoot.standardizedFileURL.path
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"

        func rebaseURL(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            guard path == sourcePath || path.hasPrefix(sourcePrefix) else {
                return url
            }
            guard path != sourcePath else { return destinationRoot }
            let suffix = String(path.dropFirst(sourcePrefix.count))
            return destinationRoot.appendingPathComponent(suffix)
        }

        result.documentDirectory = rebaseURL(result.documentDirectory)
        result.contentDirectory = rebaseURL(result.contentDirectory)
        result.coverImageURL = result.coverImageURL.map(rebaseURL)
        result.chapterContentURLs = result.chapterContentURLs.mapValues(rebaseURL)
        if case .epub(let localURL) = result.book.source {
            result.book.source = .epub(localURL: rebaseURL(localURL))
        }
        result.book.coverImagePath = result.coverImageURL?.path
        return result
    }

    /// Move a validated staging directory into the managed library. If a
    /// previous copy exists, move it aside and return its backup URL so the
    /// caller can roll back if the index write fails.
    private func replaceBookDirectory(
        _ stagingDirectory: URL,
        with finalDirectory: URL
    ) throws -> URL? {
        let fileManager = FileManager.default
        let backupRoot = rootDirectory.appendingPathComponent(".backups", isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let hadExistingDirectory = fileManager.fileExists(atPath: finalDirectory.path)
        let backupDirectory: URL?
        if hadExistingDirectory {
            let candidate = backupRoot.appendingPathComponent(
                "\(finalDirectory.lastPathComponent)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: finalDirectory, to: candidate)
            backupDirectory = candidate
        } else {
            backupDirectory = nil
        }

        do {
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            return backupDirectory
        } catch {
            if let backupDirectory {
                try? fileManager.moveItem(at: backupDirectory, to: finalDirectory)
            }
            throw error
        }
    }

    /// Re-parse the on-disk EPUB to recover chapter HTML URLs. We keep
    /// `original.epub` so EPUBKit can re-extract on demand; the resulting
    /// extracted directory is owned by EPUBKit's temp space, which is fine
    /// for read-only access during a session.
    private func rebuildBook(from entry: EPUBLibraryIndexEntry) async -> ReaderBook? {
        guard !entry.isDeleted else { return nil }
        let epubURL = rootDirectory
            .appendingPathComponent(entry.bookID, isDirectory: true)
            .appendingPathComponent("original.epub")
        guard FileManager.default.fileExists(atPath: epubURL.path) else { return nil }
        do {
            let parsed = try await parser.parse(fileURL: epubURL)
            chapterURLCache[entry.bookID] = parsed.chapterContentURLs
            contentRootCache[entry.bookID] = parsed.contentDirectory
            return parsed.book
        } catch {
            return nil
        }
    }

    private func writeIndex() throws {
        let url = rootDirectory.appendingPathComponent("index.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(index)
        try data.write(to: url, options: .atomic)
    }

    private static func readIndex(at root: URL) -> EPUBLibraryIndexFile? {
        let url = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let index = try? decoder.decode(EPUBLibraryIndexFile.self, from: data) {
            return index
        }
        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        return try? legacyDecoder.decode(EPUBLibraryIndexFile.self, from: data)
    }
}
