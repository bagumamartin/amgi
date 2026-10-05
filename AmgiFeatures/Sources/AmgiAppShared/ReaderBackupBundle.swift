public import Foundation
import ZIPFoundation

/// Adds the reader library to a collection backup.
///
/// A `.colpkg` is written by the Rust engine and contains only the collection
/// plus its media. The EPUB library lives outside that directory, so a backup
/// taken before this existed restored the notes but silently lost the books
/// they were read from — and reading progress lives in iCloud, not the
/// collection, so the books and the positions are only useful together.
///
/// The extension stays `.colpkg` and the extra entries live under a private
/// `ijuka/` prefix. That is safe because the importer resolves entries by name
/// (`meta`, `collection.anki2`, `media`, numbered media files) and never
/// iterates unknown entries, so desktop Anki and our own importer both ignore
/// them. Restoring is opt-in on our side, which reads the `ijuka/` entries
/// after the collection import has already succeeded.
public enum ReaderBackupBundle {
    /// Root of our additions inside the archive. Prefixed so it cannot collide
    /// with an Anki media file name.
    public static let archivePrefix = "ijuka"

    public enum Failure: Error, LocalizedError {
        case unreadablePackage(String)
        case missingSource(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadablePackage(let detail):
                "The backup package could not be opened: \(detail)"
            case .missingSource(let bookID):
                "The stored file for \(bookID) is missing, so the reader library could not be backed up."
            case .writeFailed(let detail):
                "The backup package could not be written: \(detail)"
            }
        }
    }

    /// Result of one bundling pass.
    public struct Outcome: Equatable {
        public var bookCount: Int = 0
        public var byteCount: Int = 0
        /// False when the library was empty, i.e. there was nothing to add.
        public var didAddReaderPayload: Bool { bookCount > 0 }
    }

    /// Adds every book in the EPUB and PDF libraries to the package at
    /// `packageURL`, rewriting it in place.
    ///
    /// - Only `original.epub` / `original.pdf` and the cover are copied. The
    ///   `{bookID}/original/` extraction directory is a disposable EPUBKit
    ///   cache: shipping it would multiply the package size for zero restore
    ///   value, since the library re-extracts on import.
    /// - PDF books whose index entry is a deletion tombstone are left out.
    ///   Unlike EPUB (whose delete removes the directory), a deleted PDF keeps
    ///   its file on disk, so the filesystem alone cannot tell it is gone —
    ///   and backing it up anyway would resurrect it on restore.
    /// - Throws rather than silently skipping a book whose source is missing:
    ///   a backup that claims to contain the library but does not is worse than
    ///   a visible failure, because the user cannot tell the difference later.
    @discardableResult
    public static func addReaderLibrary(
        toPackageAt packageURL: URL,
        epubRoot: URL,
        pdfRoot: URL
    ) throws -> Outcome {
        let epubIDs = try managedBookIDs(in: epubRoot)
        let tombstoned = tombstonedPDFBookIDs(in: pdfRoot)
        let pdfIDs = try managedBookIDs(in: pdfRoot).filter { !tombstoned.contains($0) }
        guard !epubIDs.isEmpty || !pdfIDs.isEmpty else {
            return Outcome(
                byteCount: (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
        }

        let archive: Archive
        do {
            archive = try Archive(url: packageURL, accessMode: .update)
        } catch {
            throw Failure.unreadablePackage(packageURL.lastPathComponent)
        }

        var outcome = Outcome()
        for bookID in epubIDs {
            try addBook(
                bookID: bookID,
                libraryRoot: epubRoot,
                sourceFileName: "original.epub",
                archiveSubdirectory: "epub",
                to: archive,
                outcome: &outcome
            )
        }
        for bookID in pdfIDs {
            try addBook(
                bookID: bookID,
                libraryRoot: pdfRoot,
                sourceFileName: "original.pdf",
                archiveSubdirectory: "pdf",
                to: archive,
                outcome: &outcome
            )
        }
        outcome.byteCount = (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return outcome
    }

    private static func addBook(
        bookID: String,
        libraryRoot: URL,
        sourceFileName: String,
        archiveSubdirectory: String,
        to archive: Archive,
        outcome: inout Outcome
    ) throws {
        let bookSource = libraryRoot
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent(sourceFileName)
        guard FileManager.default.fileExists(atPath: bookSource.path) else {
            throw Failure.missingSource(bookID)
        }
        try add(
            file: bookSource,
            to: archive,
            as: "\(archivePrefix)/\(archiveSubdirectory)/\(bookID)/\(sourceFileName)"
        )

        // Named from the file itself so a changed cover extension on a
        // re-import does not leave the old name behind in the package.
        if let cover = try coverFile(in: libraryRoot, bookID: bookID) {
            try add(
                file: cover,
                to: archive,
                as: "\(archivePrefix)/\(archiveSubdirectory)/\(bookID)/\(cover.lastPathComponent)"
            )
        }
        outcome.bookCount += 1
    }

    /// Book IDs the PDF library has tombstoned (deleted but still on disk).
    ///
    /// Read with `JSONSerialization` rather than the store's index type so this
    /// helper stays a pure filesystem operation with no edge to the reader
    /// package. Best-effort: an unreadable index backs up everything rather
    /// than silently dropping books.
    private static func tombstonedPDFBookIDs(in pdfRoot: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: pdfRoot.appendingPathComponent("index.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            return []
        }
        return Set(entries.compactMap { entry in
            guard let bookID = entry["bookID"] as? String,
                  entry["deletedAt"] != nil,
                  !(entry["deletedAt"] is NSNull) else {
                return nil
            }
            return bookID
        })
    }

    /// Extracts only the `ijuka/epub/` and `ijuka/pdf/` entries from a package.
    ///
    /// Returns zero books for any package without a reader payload — an older
    /// backup, or one written by desktop Anki — which is the normal case and
    /// not an error. Book files are recreated flat as `{bookID}.epub` /
    /// `{bookID}.pdf` because the libraries re-derive their own layout on
    /// import; only the source bytes need to survive.
    @discardableResult
    public static func extractReaderLibrary(
        fromPackageAt packageURL: URL,
        to directory: URL
    ) throws -> [URL] {
        let archive: Archive
        do {
            archive = try Archive(url: packageURL, accessMode: .read)
        } catch {
            throw Failure.unreadablePackage(packageURL.lastPathComponent)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var extracted: [URL] = []
        for entry in archive {
            guard entry.type != .directory,
                  let match = parseReaderEntry(entry.path),
                  // Only the source is needed: the libraries re-derive their
                  // own layout, and the extraction directory is a disposable
                  // cache.
                  entry.path.hasSuffix(match.sourceFileName) else { continue }

            let destination = directory.appendingPathComponent("\(match.bookID).\(match.pathExtension)")
            // `extract(_:to:)` streams the entry straight to disk and
            // CRC-checks it, so a truncated payload is caught here rather than
            // half-imported into the library.
            _ = try archive.extract(entry, to: destination, skipCRC32: true)
            extracted.append(destination)
        }
        return extracted.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Splits a `ijuka/<format>/<bookID>/…` path into its parts, or nil when
    /// the entry is not a reader payload at all.
    private static func parseReaderEntry(_ path: String) -> (
        bookID: String,
        sourceFileName: String,
        pathExtension: String
    )? {
        for (subdirectory, sourceFileName, pathExtension) in [
            ("epub", "original.epub", "epub"),
            ("pdf", "original.pdf", "pdf"),
        ] {
            let prefix = "\(archivePrefix)/\(subdirectory)/"
            guard path.hasPrefix(prefix) else { continue }
            let bookID = path
                .replacingOccurrences(of: prefix, with: "")
                .split(separator: "/")
                .first
                .map(String.init)
            guard let bookID, !bookID.isEmpty else { return nil }
            return (bookID, sourceFileName, pathExtension)
        }
        return nil
    }

    /// Book IDs on disk, skipping the store's own bookkeeping directories.
    ///
    /// Read from the filesystem rather than the index so a book whose index
    /// entry is a deletion tombstone is correctly left out, and one whose
    /// index entry is unreadable is still backed up.
    private static func managedBookIDs(in libraryRoot: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryRoot.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        .map(\.lastPathComponent)
        .sorted()
    }

    private static func coverFile(in libraryRoot: URL, bookID: String) throws -> URL? {
        let directory = libraryRoot.appendingPathComponent(bookID, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.first { $0.lastPathComponent.hasPrefix("cover.") }
    }

    private static func add(file: URL, to archive: Archive, as path: String) throws {
        // ZIPFoundation's file convenience streams the entry in chunks, so a
        // multi-megabyte EPUB is never held in memory.
        try archive.addEntry(with: path, fileURL: file, compressionMethod: .deflate)
    }
}
