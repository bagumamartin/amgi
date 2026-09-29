import Foundation
import Testing
import ZIPFoundation
@testable import AmgiAppShared

/// The reader library has to survive a backup/restore round trip, and the
/// payload has to stay invisible to Anki's own importer — which resolves
/// entries by name and never iterates unknown ones.
@Suite("Reader backup bundle")
struct ReaderBackupBundleTests {
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal stand-in for a colpkg: the named entries Anki's importer
    /// looks for, so the test proves our additions coexist with them.
    private func makeColpkg(at url: URL) throws {
        let payload: [String: Data] = [
            "meta": Data("stub-meta".utf8),
            "collection.anki2": Data("stub-collection".utf8),
            "0": Data("stub-media".utf8),
        ]
        // In `.create` mode the archive is written when it goes out of scope,
        // so the scope below is what actually produces the file.
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for (path, data) in payload {
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    provider: { _, _ in data }
                )
            }
        }
    }

    private func makeLibrary(at root: URL, bookIDs: [String]) throws {
        for bookID in bookIDs {
            let directory = root.appendingPathComponent(bookID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("epub-bytes-\(bookID)".utf8)
                .write(to: directory.appendingPathComponent("original.epub"))
            try Data("cover-\(bookID)".utf8)
                .write(to: directory.appendingPathComponent("cover.jpg"))
            // A disposable extraction directory that must NOT be packaged.
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("original", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("extracted".utf8)
                .write(to: directory.appendingPathComponent("original/chapter.xhtml"))
        }
    }

    @Test("a backup gains the books and keeps every Anki entry")
    func roundTripPreservesAnkiEntries() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let package = scratch.appendingPathComponent("backup.colpkg")
        try makeColpkg(at: package)
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        try makeLibrary(at: library, bookIDs: ["epub-a", "epub-b"])

        let outcome = try ReaderBackupBundle.addReaderLibrary(
            toPackageAt: package,
            libraryRoot: library
        )
        #expect(outcome.bookCount == 2)
        #expect(outcome.didAddReaderPayload)

        let archive = try #require(Archive(url: package, accessMode: .read))
        let paths = Set(archive.map(\.path))

        // Anki's entries survive untouched.
        for required in ["meta", "collection.anki2", "0"] {
            #expect(paths.contains(required), "expected \(required) to survive")
        }
        // Our payload is present and namespaced.
        #expect(paths.contains("ijuka/epub/epub-a/original.epub"))
        #expect(paths.contains("ijuka/epub/epub-b/original.epub"))
        #expect(paths.contains("ijuka/epub/epub-a/cover.jpg"))
        // The disposable extraction cache is never packaged.
        #expect(!paths.contains(where: { $0.contains("original/") && $0.hasSuffix(".xhtml") }))
    }

    @Test("the packaged bytes are the real source, not a re-encode")
    func packagedBytesMatchSource() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let package = scratch.appendingPathComponent("backup.colpkg")
        try makeColpkg(at: package)
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        try makeLibrary(at: library, bookIDs: ["epub-a"])

        try ReaderBackupBundle.addReaderLibrary(
            toPackageAt: package,
            libraryRoot: library
        )

        let extracted = scratch.appendingPathComponent("extracted", isDirectory: true)
        let files = try ReaderBackupBundle.extractReaderLibrary(
            fromPackageAt: package,
            to: extracted
        )
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "epub-a.epub")
        let data = try Data(contentsOf: files[0])
        #expect(data == Data("epub-bytes-epub-a".utf8))
    }

    @Test("a package with no reader payload extracts cleanly as empty")
    func packageWithoutPayloadIsNotAnError() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let package = scratch.appendingPathComponent("plain.colpkg")
        try makeColpkg(at: package)
        let extracted = scratch.appendingPathComponent("out", isDirectory: true)
        let files = try ReaderBackupBundle.extractReaderLibrary(
            fromPackageAt: package,
            to: extracted
        )
        // This is the normal case for any backup taken before reader backups
        // existed, and for one written by desktop Anki.
        #expect(files.isEmpty)
    }

    @Test("an empty library leaves the package untouched")
    func emptyLibraryIsANoOp() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let package = scratch.appendingPathComponent("backup.colpkg")
        try makeColpkg(at: package)
        let before = try Data(contentsOf: package)

        let library = scratch.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let outcome = try ReaderBackupBundle.addReaderLibrary(
            toPackageAt: package,
            libraryRoot: library
        )
        #expect(outcome.bookCount == 0)
        #expect(outcome.didAddReaderPayload == false)
        #expect(try Data(contentsOf: package) == before)
    }

    @Test("a book whose source vanished fails loudly rather than being skipped")
    func missingSourceFailsLoudly() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let package = scratch.appendingPathComponent("backup.colpkg")
        try makeColpkg(at: package)
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        // A directory with no original.epub: exactly the state the repair UI
        // exists for. Silently dropping it would produce a backup that looks
        // complete but is not.
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("epub-broken", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(throws: ReaderBackupBundle.Failure.self) {
            try ReaderBackupBundle.addReaderLibrary(
                toPackageAt: package,
                libraryRoot: library
            )
        }
    }

    @Test("the archive prefix cannot collide with an Anki media name")
    func prefixIsNamespaced() {
        // Media files are bare integers, so any prefixed path is unambiguous.
        #expect(ReaderBackupBundle.archivePrefix == "ijuka")
        #expect("ijuka/epub/epub-a/original.epub".hasPrefix("ijuka/"))
    }
}
