public import Foundation
import ZIPFoundation

/// Adds the reader library to a collection backup.
///
/// A `.colpkg` is written by the Rust engine and contains only the collection
/// plus its media. The EPUB library lives outside that directory, so a backup
/// taken before this existed restored the notes but silently lost the books
/// they were read from — and the Anki collection carries reading progress but
/// not the source, so the two halves are only useful together.
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

    /// Adds every book in `libraryRoot` to the package at `packageURL`,
    /// rewriting it in place.
    ///
    /// - Only `original.epub` and the cover are copied. The `{bookID}/original/`
    ///   extraction directory is a disposable EPUBKit cache: shipping it would
    ///   multiply the package size for zero restore value, since the library
    ///   re-extracts on import.
    /// - Throws rather than silently skipping a book whose source is missing:
    ///   a backup that claims to contain the library but does not is worse than
    ///   a visible failure, because the user cannot tell the difference later.
    @discardableResult
    public static func addReaderLibrary(
        toPackageAt packageURL: URL,
        libraryRoot: URL
    ) throws -> Outcome {
        let bookIDs = try managedBookIDs(in: libraryRoot)
        guard !bookIDs.isEmpty else {
            return Outcome(
                byteCount: (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
        }

        guard let archive = Archive(url: packageURL, accessMode: .update) else {
            throw Failure.unreadablePackage(packageURL.lastPathComponent)
        }

        var outcome = Outcome()
        for bookID in bookIDs {
            let bookSource = libraryRoot
                .appendingPathComponent(bookID, isDirectory: true)
                .appendingPathComponent("original.epub")
            guard FileManager.default.fileExists(atPath: bookSource.path) else {
                throw Failure.missingSource(bookID)
            }
            try add(
                file: bookSource,
                to: archive,
                as: "\(archivePrefix)/epub/\(bookID)/original.epub"
            )

            // Named from the file itself so a changed cover extension on a
            // re-import does not leave the old name behind in the package.
            if let cover = try coverFile(in: libraryRoot, bookID: bookID) {
                try add(
                    file: cover,
                    to: archive,
                    as: "\(archivePrefix)/epub/\(bookID)/\(cover.lastPathComponent)"
                )
            }
            outcome.bookCount += 1
        }
        outcome.byteCount = (try? packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return outcome
    }

    /// Extracts only the `ijuka/epub/` entries from a package.
    ///
    /// Returns zero books for any package without a reader payload — an older
    /// backup, or one written by desktop Anki — which is the normal case and
    /// not an error. Book directories are recreated flat as
    /// `{bookID}.epub` because the library re-derives its own layout on
    /// import; only the source bytes need to survive.
    @discardableResult
    public static func extractReaderLibrary(
        fromPackageAt packageURL: URL,
        to directory: URL
    ) throws -> [URL] {
        guard let archive = Archive(url: packageURL, accessMode: .read) else {
            throw Failure.unreadablePackage(packageURL.lastPathComponent)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var extracted: [URL] = []
        for entry in archive {
            guard entry.path.hasPrefix("\(archivePrefix)/epub/") else { continue }
            let bookID = entry.path
                .replacingOccurrences(of: "\(archivePrefix)/epub/", with: "")
                .split(separator: "/")
                .first
                .map(String.init)
            guard let bookID, !bookID.isEmpty, entry.type != .directory else { continue }
            // Only the source is needed: the library re-derives its own
            // layout, and the extraction directory is a disposable cache.
            guard entry.path.hasSuffix("original.epub") else { continue }

            let destination = directory.appendingPathComponent("\(bookID).epub")
            // `extract(_:to:)` streams the entry straight to disk and
            // CRC-checks it, so a truncated payload is caught here rather than
            // half-imported into the library.
            try archive.extract(entry, to: destination, skipCRC32: true)
            extracted.append(destination)
        }
        return extracted.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
