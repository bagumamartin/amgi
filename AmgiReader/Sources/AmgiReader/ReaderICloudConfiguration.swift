public import Foundation

/// The app-owned iCloud Drive container shared by everything reader-side.
///
/// One container for EPUB books, PDF books and reading progress, so book
/// data has a single sync home — and so none of it ever needs the Anki
/// collection. The container must be registered for the app's Apple Developer
/// team before the capability can be signed; the existing CloudDocuments
/// entitlement already covers it, so no new entitlements are required.
///
/// Layout inside the container:
/// ```
/// Documents/Books/{Readable Title}.epub|.pdf   ← public: shown in Files
/// Library/EPUB/books/{bookID}/metadata.json    ← private sidecars (+ cover)
/// Library/PDF/books/{bookID}/metadata.json
/// Library/ReaderProgress/{profileID}/manifest.json
/// ```
/// Only `Documents/` is visible in Files (the container is declared public
/// through `NSUbiquitousContainers` in the app's Info.plist), so the user
/// sees one folder of plainly named books and nothing else. Everything the
/// app needs to match a file back to a book lives outside `Documents/`.
public enum ReaderICloudConfiguration {
    public static let defaultContainerIdentifier = "iCloud.com.bagumamartin.ijuka"

    /// The public folder of book files, under `Documents/`.
    public static let booksDirectoryName = "Books"

    /// The container root, or nil when there is no iCloud account. Tests pass
    /// `overrideRoot` to stand in a plain directory.
    ///
    /// Never call this on the main actor: resolving the container can block
    /// while iCloud sets it up.
    public static func containerURL(
        identifier: String = defaultContainerIdentifier,
        overrideRoot: URL?
    ) -> URL? {
        if let overrideRoot { return overrideRoot }
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        return FileManager.default.url(forUbiquityContainerIdentifier: identifier)
    }

    /// The public, user-visible folder of book files.
    public static func booksFolderURL(in container: URL) -> URL {
        container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(booksDirectoryName, isDirectory: true)
    }

    /// Private app data that syncs but never appears in Files.
    public static func privateURL(_ name: String, in container: URL) -> URL {
        container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Where a directory used to live before the container went public, when
    /// everything sat under `Documents/` with opaque book-ID folder names.
    public static func legacyDocumentsURL(_ name: String, in container: URL) -> URL {
        container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}

/// Human-readable file names for the public `Documents/Books` folder.
public enum ReaderICloudBookNaming {
    static let maximumBaseLength = 120

    /// A title made safe as a single file name: no path separators, no
    /// leading dot (which would hide the file), no control characters.
    public static func baseName(forTitle title: String) -> String {
        var cleaned = String(title.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            return Character(scalar)
        })
        cleaned = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > maximumBaseLength {
            cleaned = String(cleaned.prefix(maximumBaseLength))
                .trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Whether `fileName` is the name this title would get, allowing the
    /// ` (n)` suffix a collision adds.
    public static func fileName(
        _ fileName: String,
        matchesTitle title: String,
        fileExtension: String
    ) -> Bool {
        let base = baseName(forTitle: title)
        let suffix = "." + fileExtension
        guard fileName.hasSuffix(suffix) else { return false }
        let stem = String(fileName.dropLast(suffix.count))
        if stem == base { return true }
        guard stem.hasPrefix(base + " ("), stem.hasSuffix(")") else { return false }
        let number = stem.dropFirst(base.count + 2).dropLast()
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    /// A file name for `title` that nothing in `folder` already uses:
    /// `Title.epub`, then `Title (2).epub`, `Title (3).epub`, …
    public static func availableFileName(
        forTitle title: String,
        fileExtension: String,
        in folder: URL,
        claimed: Set<String> = []
    ) -> String {
        let base = baseName(forTitle: title)
        var candidate = "\(base).\(fileExtension)"
        var number = 2
        while claimed.contains(candidate) || isTaken(candidate, in: folder) {
            candidate = "\(base) (\(number)).\(fileExtension)"
            number += 1
        }
        return candidate
    }

    /// The name to upload a book under. Keeps the name the book already has
    /// while it still matches the title and no other book's metadata claims
    /// it, so re-uploads never shuffle names; otherwise picks a free one.
    ///
    /// `claimedByOthers` matters because a file name alone cannot say whose
    /// it is: if the user deletes `Dune.epub` and a different book titled
    /// "Dune" takes the name, the first book must not write over it.
    public static func uploadFileName(
        forTitle title: String,
        fileExtension: String,
        existing: String?,
        claimedByOthers: Set<String>,
        in folder: URL
    ) -> String {
        if let existing,
           isSafeFileName(existing),
           !claimedByOthers.contains(existing),
           fileName(existing, matchesTitle: title, fileExtension: fileExtension) {
            return existing
        }
        return availableFileName(
            forTitle: title,
            fileExtension: fileExtension,
            in: folder,
            claimed: claimedByOthers
        )
    }

    /// True when `fileName` exists in `folder`, either materialized or as an
    /// iCloud `.{name}.icloud` placeholder.
    public static func isTaken(_ fileName: String, in folder: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: folder.appendingPathComponent(fileName).path)
            || fileManager.fileExists(
                atPath: folder.appendingPathComponent(".\(fileName).icloud").path
            )
    }

    /// A name that can safely be joined onto the books folder.
    public static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && !fileName.hasPrefix(".")
            && !fileName.contains("/")
            && !fileName.contains("\\")
    }
}

/// Coordinated file moves inside the ubiquity container. A coordinated move
/// renames an iCloud item in place — it works on placeholders that have not
/// been downloaded, so migrating a layout never pulls book data over the
/// network.
public enum ReaderICloudFiles {
    public static func coordinatedMove(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: (any Error)?
        coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                coordinator.item(at: coordinatedSource, willMoveTo: coordinatedDestination)
                try fileManager.moveItem(at: coordinatedSource, to: coordinatedDestination)
                coordinator.item(at: coordinatedSource, didMoveTo: coordinatedDestination)
            } catch {
                moveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    public static func coordinatedRemove(at url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var removeError: (any Error)?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinated in
            do {
                try FileManager.default.removeItem(at: coordinated)
            } catch {
                removeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }

    /// Removes `directory` if it is empty. Hidden files count as content —
    /// an undownloaded iCloud item is a hidden `.{name}.icloud` placeholder,
    /// and deleting it would delete the cloud copy — except Finder's
    /// `.DS_Store`.
    public static func removeIfEmpty(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ), contents.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else { return }
        try? coordinatedRemove(at: directory)
    }
}
