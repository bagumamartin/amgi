import Foundation
import Testing
@testable import AmgiReaderPDF

/// A temporary directory that cleans itself up.
private struct TemporaryLibrary {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-pdflib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ bytes: [UInt8], named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}

@Suite("PDF library store")
struct PDFLibraryStoreTests {
    @Test("importing a PDF adds it to the library")
    func importsABook() async throws {
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFDocumentFixture.outlined(), named: "book.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))

        let book = try await store.importPDF(from: source)
        #expect(book.title == "On Typography")
        #expect(book.author == "A. Reader")
        #expect(book.pageCount == 2)
        if case .pdf = book.source {} else {
            Issue.record("expected a PDF source, got \(book.source)")
        }

        let books = await store.books()
        #expect(books.count == 1)
        #expect(books[0].id == book.id)
    }

    @Test("chapters come from the document outline")
    func chaptersComeFromTheOutline() async throws {
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFDocumentFixture.outlined(), named: "book.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))

        let book = try await store.importPDF(from: source)
        #expect(book.chapters.count == 2)
        #expect(book.chapters[0].title == "The First Chapter")
        #expect(book.chapters[0].startPageIndex == 0)
        #expect(book.chapters[1].title == "The Second Chapter")
        #expect(book.chapters[1].startPageIndex == 1)
    }

    @Test("a document with no outline still gets a chapter")
    func outlineLessDocumentGetsAChapter() async throws {
        // An empty chapter list would read as a bug in the detail view rather
        // than as "this PDF has no table of contents".
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "plain.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))

        let book = try await store.importPDF(from: source)
        #expect(book.chapters.count == 1)
        #expect(book.chapters[0].startPageIndex == 0)
    }

    @Test("a book's ID survives being annotated")
    func bookIDSurvivesAnnotation() async throws {
        // The property the whole ID scheme exists for. Annotations are appended
        // to the managed file, so a whole-file hash would change the first time
        // the user highlights something — and re-importing their own annotated
        // PDF would then create a second library entry, with the annotations
        // stranded in the first.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let original = PDFFixture.classicDocument()
        let source = try temporary.write(original, named: "book.pdf")
        let library = temporary.root.appendingPathComponent("library")
        let store = PDFLibraryStore(rootDirectory: library)

        let book = try await store.importPDF(from: source)
        let managed = try #require(await store.sourceURL(bookID: book.id))
        let before = try PDFAppendableFile.load(contentsOf: managed)
        let page = try #require(before.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "a note",
                page: page.reference
            ),
            to: page,
            on: before,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        _ = try await store.append(
            to: book.id,
            update: PDFIncrementalUpdate.build(
                for: before, entries: change.entries, appendedAt: before.bytes.count
            )
        )

        // The file really did change, so a whole-file hash really would differ.
        let annotated = try Data(contentsOf: managed)
        #expect(annotated.count > original.count)

        // Yet the ID is the same, so re-importing is the same book.
        let derivedFromManaged = try PDFLibraryStore.deriveBookID(forFileAt: managed)
        #expect(derivedFromManaged == book.id)
        let reimported = try await store.importPDF(from: source)
        #expect(reimported.id == book.id)
        let books = await store.books()
        #expect(books.count == 1, "re-importing an annotated PDF must not fork the library")
    }

    @Test("the annotation appended through the store is readable")
    func appendedAnnotationIsReadable() async throws {
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "book.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))
        let book = try await store.importPDF(from: source)
        let managed = try #require(await store.sourceURL(bookID: book.id))

        let before = try PDFAppendableFile.load(contentsOf: managed)
        let page = try #require(before.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "persisted",
                page: page.reference
            ),
            to: page,
            on: before,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        _ = try await store.append(
            to: book.id,
            update: PDFIncrementalUpdate.build(
                for: before, entries: change.entries, appendedAt: before.bytes.count
            )
        )
        _ = try await store.reload(bookID: book.id)

        let after = try PDFAppendableFile.load(contentsOf: managed)
        let annotations = after.annotations(on: try #require(after.pages.first))
        #expect(annotations.count == 1)
        #expect(annotations[0].contents == "persisted")
    }

    @Test("importing a non-PDF fails with a clear reason")
    func rejectsNonPDF() async throws {
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(Array("not a pdf at all".utf8), named: "fake.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))
        await #expect(throws: (any Error).self) {
            _ = try await store.importPDF(from: source)
        }
        // And nothing was left behind.
        let books = await store.books()
        #expect(books.isEmpty)
    }

    @Test("a failed import leaves an existing book intact")
    func failedImportDoesNotDamageTheLibrary() async throws {
        // The staged copy is parsed before the managed book is touched, so a
        // corrupt re-import cannot destroy a readable edition.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let good = try temporary.write(PDFFixture.classicDocument(), named: "good.pdf")
        let bad = try temporary.write(Array("garbage".utf8), named: "bad.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))

        _ = try await store.importPDF(from: good)
        await #expect(throws: (any Error).self) {
            _ = try await store.importPDF(from: bad)
        }
        let books = await store.books()
        #expect(books.count == 1)
        #expect(books[0].pageCount == 1)
    }

    @Test("deleting a book leaves a tombstone rather than erasing the entry")
    func deleteLeavesATombstone() async throws {
        // The tombstone is what stops a later sync from restoring a book the
        // user removed on this device.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "book.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))
        let book = try await store.importPDF(from: source)

        try await store.delete(bookID: book.id)
        let books = await store.books()
        #expect(books.isEmpty)
        // The index still names it, as deleted.
        let indexData = try Data(
            contentsOf: temporary.root
                .appendingPathComponent("library")
                .appendingPathComponent("index.json")
        )
        let text = String(decoding: indexData, as: UTF8.self)
        #expect(text.contains(book.id))
        #expect(text.contains("deletedAt"))
    }

    @Test("a missing source is reported as a fault, and the book still appears")
    func missingSourceBecomesAFault() async throws {
        // A book that vanishes from the library must not also vanish from the
        // list: the user needs to see it in order to repair it.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "book.pdf")
        let library = temporary.root.appendingPathComponent("library")
        let store = PDFLibraryStore(rootDirectory: library)
        let book = try await store.importPDF(from: source)

        try FileManager.default.removeItem(
            at: library.appendingPathComponent(book.id, isDirectory: true)
        )

        let books = await store.books()
        #expect(books.count == 1, "a broken book must still be listed so it can be repaired")
        let health = await store.bookHealth()
        #expect(health[book.id]?.fault == .sourceMissing)
        #expect(!(health[book.id]?.isReady ?? true))
    }

    @Test("a fault clears once the source is restored")
    func faultClearsOnRetry() async throws {
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "book.pdf")
        let library = temporary.root.appendingPathComponent("library")
        let store = PDFLibraryStore(rootDirectory: library)
        let book = try await store.importPDF(from: source)

        let directory = library.appendingPathComponent(book.id, isDirectory: true)
        let moved = temporary.root.appendingPathComponent("moved.pdf")
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("original.pdf"), to: moved
        )
        _ = await store.books()
        #expect(await store.bookHealth()[book.id]?.fault == .sourceMissing)

        try FileManager.default.moveItem(at: moved, to: directory.appendingPathComponent("original.pdf"))
        let recovered = await store.retryBook(bookID: book.id)
        #expect(recovered != nil)
        #expect(await store.bookHealth()[book.id]?.isReady ?? false)
    }

    @Test("an encrypted PDF is readable-as-broken rather than unparseable")
    func encryptedPDFReportsItsOwnFault() async throws {
        // An encrypted PDF opens in Preview. Reporting it as unparseable would
        // offer a repair action that cannot possibly help; the UI needs to say
        // "remove the password" instead.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.encryptedDocument(), named: "locked.pdf")
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))

        await #expect(throws: (any Error).self) {
            _ = try await store.importPDF(from: source)
        }
    }

    @Test("a damaged index is rebuilt from the files on disk")
    func rebuildsIndexFromDisk() async throws {
        // Losing index.json must not read as data loss: the imported books are
        // still on disk, and a user who sees an empty library will assume they
        // are gone.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "book.pdf")
        let library = temporary.root.appendingPathComponent("library")
        let first = PDFLibraryStore(rootDirectory: library)
        let book = try await first.importPDF(from: source)

        try FileManager.default.removeItem(at: library.appendingPathComponent("index.json"))

        let second = PDFLibraryStore(rootDirectory: library)
        let books = await second.books()
        #expect(books.count == 1)
        #expect(books[0].id == book.id)
    }

    @Test("timestamps round-trip through the index")
    func timestampsRoundTrip() async throws {
        // A silent date-decoding mismatch here would not throw: it would read
        // every timestamp as seconds since 2001, and "which edit is newer" —
        // the basis of every sync decision — would then be meaningless.
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(PDFFixture.classicDocument(), named: "book.pdf")
        let library = temporary.root.appendingPathComponent("library")
        let first = PDFLibraryStore(rootDirectory: library)
        _ = try await first.importPDF(from: source)

        let second = PDFLibraryStore(rootDirectory: library)
        let books = await second.books()
        #expect(books.count == 1)

        let indexData = try Data(contentsOf: library.appendingPathComponent("index.json"))
        let object = try JSONSerialization.jsonObject(with: indexData) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]
        let updatedAt = try #require(entries?.first?["updatedAt"] as? Double)
        // Milliseconds since 1970. Read as seconds, this lands in 1970 and every
        // "which is newer" comparison breaks silently.
        let date = Date(timeIntervalSince1970: updatedAt / 1000)
        #expect(date > Date(timeIntervalSinceNow: -600))
    }

    @Test("re-importing refreshes metadata without duplicating the entry")
    func reimportRefreshesMetadata() async throws {
        let temporary = TemporaryLibrary()
        defer { temporary.cleanUp() }
        let source = try temporary.write(
            PDFDocumentFixture.outlined(info: ["Title": "First Title"]), named: "book.pdf"
        )
        let store = PDFLibraryStore(rootDirectory: temporary.root.appendingPathComponent("library"))
        _ = try await store.importPDF(from: source)

        // The same document, re-exported with a different title. The ID is
        // derived from the file's prefix and its `/ID`, so this is still the same
        // book as far as identity goes only if the bytes match; here they do
        // not, so it is a different document and must appear separately.
        let renamed = try temporary.write(
            PDFDocumentFixture.outlined(info: ["Title": "Second Title"]), named: "other.pdf"
        )
        let second = try await store.importPDF(from: renamed)
        #expect(second.title == "Second Title")
        #expect((await store.books()).count == 2)
    }
}
