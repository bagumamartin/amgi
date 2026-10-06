import Foundation
import Testing
@testable import AmgiReaderEPUB

#if os(macOS)
@Suite("EPUB library reliability")
struct EPUBLibraryStoreTests {
    @Test("import commits reader URLs under the managed book directory")
    func importRebasesManagedURLs() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)

        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)
        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let book = try await store.importEPUB(from: sourceURL)

        #expect(book.title == "Test Publication")
        #expect(book.chapters.count == 1)
        #expect(book.chapters[0].title == "Chapter 1")

        guard case .epub(let localURL) = book.source else {
            Issue.record("Expected an EPUB source")
            return
        }
        #expect(localURL.path.hasPrefix(libraryRoot.path + "/"))

        let chapterURL = await store.contentURL(
            bookID: book.id,
            chapterID: book.chapters[0].id
        )
        let contentRoot = await store.contentRootURL(bookID: book.id)
        #expect(chapterURL?.path.hasPrefix(libraryRoot.path + "/") == true)
        #expect(contentRoot?.path.hasPrefix(libraryRoot.path + "/") == true)
        #expect(chapterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        // Re-importing the same publication exercises the replacement path:
        // the old managed directory is moved aside only after the staged copy
        // parses, then the backup is removed after the index commit.
        let replacement = try await store.importEPUB(from: sourceURL)
        #expect(replacement.id == book.id)
        #expect(await store.books().count == 1)
        let replacementChapterURL = await store.contentURL(
            bookID: replacement.id,
            chapterID: replacement.chapters[0].id
        )
        #expect(replacementChapterURL?.path.hasPrefix(libraryRoot.path + "/") == true)

        let backupContents = try FileManager.default.contentsOfDirectory(
            atPath: libraryRoot.appendingPathComponent(".backups", isDirectory: true).path
        )
        #expect(backupContents.isEmpty)

        let stagingContents = try FileManager.default.contentsOfDirectory(
            atPath: libraryRoot.appendingPathComponent(".staging", isDirectory: true).path
        )
        #expect(stagingContents.isEmpty)
    }

    @Test("a failed import does not remove an existing book")
    func failedImportPreservesExistingBook() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let validSource = fixtureRoot.appendingPathComponent("valid.epub")
        try makeValidEPUB(at: validSource)
        let invalidSource = fixtureRoot.appendingPathComponent("invalid.epub")
        try Data("not an epub".utf8).write(to: invalidSource)

        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)
        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let originalBook = try await store.importEPUB(from: validSource)

        await #expect(throws: EPUBLibraryStore.StoreError.self) {
            try await store.importEPUB(from: invalidSource)
        }

        let listedBooks = await store.books()
        #expect(listedBooks.count == 1)
        #expect(listedBooks.first?.id == originalBook.id)

        let listedChapterURL = await store.contentURL(
            bookID: originalBook.id,
            chapterID: originalBook.chapters[0].id
        )
        #expect(listedChapterURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("cold start books listing uses index without re-extracting or re-parsing")
    func coldStartBooksUsesIndexDirectly() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)

        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)
        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let imported = try await store.importEPUB(from: sourceURL)

        // Simulate a cold launch with a fresh store.
        let coldStore = EPUBLibraryStore(rootDirectory: libraryRoot)
        let coldBooks = await coldStore.books()

        #expect(coldBooks.count == 1)
        #expect(coldBooks.first?.id == imported.id)
        #expect(coldBooks.first?.title == "Test Publication")
        #expect(coldBooks.first?.chapters.count == imported.chapters.count)

        // Health check on cold start is instant and reports ready
        let health = await coldStore.bookHealth()
        #expect(health[imported.id]?.isReady == true)
    }

    @Test("iCloud mirror uploads and additively restores without deleting local state")
    func iCloudMirrorRoundTrip() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)

        let cloudRoot = fixtureRoot.appendingPathComponent("icloud", isDirectory: true)
        let firstStore = EPUBLibraryStore(
            testingRootDirectory: fixtureRoot.appendingPathComponent("first", isDirectory: true),
            cloudRoot: cloudRoot
        )
        let secondStore = EPUBLibraryStore(
            testingRootDirectory: fixtureRoot.appendingPathComponent("second", isDirectory: true),
            cloudRoot: cloudRoot
        )

        let imported = try await firstStore.importEPUB(from: sourceURL)
        let firstSync = await firstStore.synchronizeWithICloud()
        #expect(firstSync.status == .completed)
        #expect(firstSync.uploadedBookIDs == [imported.id])
        let cloudLibrary = cloudRoot
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("EPUB", isDirectory: true)
        let cloudBookDirectory = cloudLibrary
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(imported.id, isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: cloudBookDirectory.appendingPathComponent("metadata.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: cloudBookDirectory.appendingPathComponent("original.epub").path
        ))

        let secondSync = await secondStore.synchronizeWithICloud()
        #expect(secondSync.status == .completed)
        #expect(secondSync.uploadedBookIDs.isEmpty)
        #expect(secondSync.restoredBookIDs == [imported.id])
        #expect(await secondStore.books().map(\.id) == [imported.id])
        #expect(await secondStore.remoteBookIDs() == [imported.id])

        // A local deletion is local-only; an explicit restore can bring the
        // retained cloud backup back through the validated import pipeline.
        try await secondStore.delete(bookID: imported.id)
        let afterDeleteSync = await secondStore.synchronizeWithICloud()
        #expect(afterDeleteSync.restoredBookIDs.isEmpty)
        #expect(await secondStore.books().isEmpty)
        let restored = try await secondStore.restoreFromICloud(bookID: imported.id)
        #expect(restored.id == imported.id)
        #expect(await secondStore.books().map(\.id) == [imported.id])

        try await firstStore.delete(bookID: imported.id)
        let deleteSync = await firstStore.synchronizeWithICloud()
        #expect(deleteSync.status == .completed)
        #expect(FileManager.default.fileExists(
            atPath: cloudBookDirectory.appendingPathComponent("original.epub").path
        ))
    }
}

#if os(macOS)
@Suite("EPUB library health and repair")
struct EPUBLibraryHealthTests {
    @Test("a missing source keeps the book listed and reports a repairable fault")
    func missingSourceIsReportedNotHidden() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)

        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)
        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let book = try await store.importEPUB(from: sourceURL)

        // Simulate the cold-start failure: the managed source vanishes (sync
        // eviction, restore abort, external cleanup).
        let managedSource = libraryRoot
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent("original.epub")
        try FileManager.default.removeItem(at: managedSource)

        // A fresh store models the next cold launch, where nothing is cached.
        let coldStore = EPUBLibraryStore(rootDirectory: libraryRoot)
        let listed = await coldStore.books()

        // The book must still occupy a row: this is the "silent disappearance"
        // regression. Title comes from the persisted index, not the parser.
        #expect(listed.count == 1)
        #expect(listed.first?.id == book.id)
        #expect(listed.first?.title == "Test Publication")

        let health = await coldStore.bookHealth()
        #expect(health[book.id]?.isReady == false)
        #expect(health[book.id]?.fault == .sourceMissing)

        // Retry cannot invent a source that is gone.
        #expect(await coldStore.retryBook(bookID: book.id) == nil)
        let healthAfterRetry = await coldStore.bookHealth()
        #expect(healthAfterRetry[book.id]?.fault == .sourceMissing)
    }

    @Test("a corrupt source reports parseFailed and relink repairs it")
    func relinkRepairsCorruptSource() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)

        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)
        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let book = try await store.importEPUB(from: sourceURL)

        let managedSource = libraryRoot
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent("original.epub")
        try Data("corrupted, not a zip".utf8).write(to: managedSource)

        let coldStore = EPUBLibraryStore(rootDirectory: libraryRoot)
        let health = await coldStore.bookHealth()
        #expect(health[book.id]?.fault == .parseFailed)
        // Still listed, still identifiable.
        let listed = await coldStore.books()
        #expect(listed.first?.id == book.id)

        // Repoint the user at a different publication: must be refused.
        let otherSource = fixtureRoot.appendingPathComponent("other.epub")
        try makeValidEPUB(at: otherSource, title: "Other Publication")
        await #expect(throws: EPUBLibraryStore.StoreError.self) {
            _ = try await coldStore.relinkBook(bookID: book.id, to: otherSource)
        }

        // Repoint at the correct file: the book is repaired and healthy again.
        let repaired = try await coldStore.relinkBook(bookID: book.id, to: sourceURL)
        #expect(repaired.id == book.id)
        let repairedHealth = await coldStore.bookHealth()
        #expect(repairedHealth[book.id]?.isReady == true)
        let repairedBooks = await coldStore.books()
        #expect(repairedBooks.first?.chapters.isEmpty == false)
    }

    @Test("a fault persisted by one store is visible to the next cold launch")
    func faultSurvivesColdRestart() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)
        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)

        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let book = try await store.importEPUB(from: sourceURL)
        try FileManager.default.removeItem(
            at: libraryRoot.appendingPathComponent(book.id, isDirectory: true)
                .appendingPathComponent("original.epub")
        )
        // Touch the fault path so it is written to index.json.
        _ = await store.books()

        // A brand-new store reads the persisted fault rather than treating the
        // book as absent.
        let coldStore = EPUBLibraryStore(rootDirectory: libraryRoot)
        let health = await coldStore.bookHealth()
        #expect(health[book.id]?.fault == .sourceMissing)
    }

    @Test("a failed rebuild keeps the previous extraction instead of wiping it")
    func failedRebuildPreservesExtraction() async throws {
        let fixtureRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sourceURL = fixtureRoot.appendingPathComponent("source.epub")
        try makeValidEPUB(at: sourceURL)
        let libraryRoot = fixtureRoot.appendingPathComponent("library", isDirectory: true)

        let store = EPUBLibraryStore(rootDirectory: libraryRoot)
        let book = try await store.importEPUB(from: sourceURL)

        // A last-good extraction alongside a source that has since been
        // corrupted underneath it.
        let bookDirectory = libraryRoot.appendingPathComponent(book.id, isDirectory: true)
        let extractionDirectory = bookDirectory.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        let sentinel = extractionDirectory.appendingPathComponent("sentinel.txt")
        try Data("last good extraction".utf8).write(to: sentinel)
        try Data("corrupted, not a zip".utf8).write(
            to: bookDirectory.appendingPathComponent("original.epub")
        )

        let coldStore = EPUBLibraryStore(rootDirectory: libraryRoot)
        let health = await coldStore.bookHealth()
        #expect(health[book.id]?.fault == .parseFailed)

        // The failed re-parse must not have destroyed the last-good
        // extraction: wiping it is what left the reader opening zero chapters
        // (blank page) on every launch after a crash mid-rebuild.
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        // And no crash-residue backup may be left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: bookDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        #expect(!leftovers.contains(where: { $0.lastPathComponent.hasPrefix(".original-backup-") }))
    }
}
#endif

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AmgiEPUBTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeValidEPUB(at archiveURL: URL, title: String = "Test Publication") throws {
    let workDirectory = archiveURL.deletingLastPathComponent()
        .appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: workDirectory.appendingPathComponent("META-INF", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: workDirectory.appendingPathComponent("OEBPS", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    try "application/epub+zip".write(
        to: workDirectory.appendingPathComponent("mimetype"),
        atomically: true,
        encoding: .utf8
    )
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.write(
        to: workDirectory.appendingPathComponent("META-INF/container.xml"),
        atomically: true,
        encoding: .utf8
    )
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(title)</dc:title>
        <dc:language>en</dc:language>
        <dc:identifier id="book-id">urn:uuid:test-publication</dc:identifier>
      </metadata>
      <manifest>
        <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="chapter"/>
      </spine>
    </package>
    """.write(
        to: workDirectory.appendingPathComponent("OEBPS/content.opf"),
        atomically: true,
        encoding: .utf8
    )
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="urn:uuid:test-publication"/></head>
      <docTitle><text>Test Publication</text></docTitle>
      <navMap>
        <navPoint id="chapter-1" playOrder="1">
          <navLabel><text>Chapter 1</text></navLabel>
          <content src="chapter.xhtml"/>
        </navPoint>
      </navMap>
    </ncx>
    """.write(
        to: workDirectory.appendingPathComponent("OEBPS/toc.ncx"),
        atomically: true,
        encoding: .utf8
    )
    try """
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>Chapter 1</title></head>
      <body><h1>Chapter 1</h1><p>A short test chapter.</p></body>
    </html>
    """.write(
        to: workDirectory.appendingPathComponent("OEBPS/chapter.xhtml"),
        atomically: true,
        encoding: .utf8
    )

    try runCommand(
        executable: "/usr/bin/zip",
        arguments: ["-X0", archiveURL.path, "mimetype"],
        workingDirectory: workDirectory
    )
    try runCommand(
        executable: "/usr/bin/zip",
        arguments: ["-Xr9", archiveURL.path, "META-INF", "OEBPS"],
        workingDirectory: workDirectory
    )
}

private func runCommand(
    executable: String,
    arguments: [String],
    workingDirectory: URL
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "EPUBLibraryStoreTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Command failed: \(executable)"]
        )
    }
}
#endif
