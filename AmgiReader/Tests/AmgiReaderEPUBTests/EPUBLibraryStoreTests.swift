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

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AmgiEPUBTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeValidEPUB(at archiveURL: URL) throws {
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
        <dc:title>Test Publication</dc:title>
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
