import Foundation
import Testing
@testable import AmgiReader

/// Highlights, bookmarks, and full-book search. The properties locked down
/// here are the ones a reader would notice immediately if they broke: a mark
/// that vanishes on relaunch, a search that misses its own text, or a
/// corruption that takes the whole library down with it.
@Suite("Reader annotation store")
struct ReaderAnnotationStoreTests {
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiAnnotations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func anchor(
        bookID: String = "book-a",
        chapterID: Int64? = 1,
        cfi: Int? = 120,
        quote: String = "the quick brown fox"
    ) -> ReaderSourceAnchor {
        ReaderSourceAnchor(
            bookID: bookID,
            chapterID: chapterID,
            chapterHref: "OEBPS/Text/ch1.xhtml",
            cfi: cfi,
            path: [0, 2, 1],
            quote: quote,
            contextBefore: "before",
            contextAfter: "after"
        )
    }

    private func highlight(
        bookID: String = "book-a",
        quote: String,
        note: String? = nil,
        createdAt: Date = .now
    ) -> ReaderAnnotation {
        ReaderAnnotation(
            bookID: bookID,
            kind: .highlight,
            anchor: anchor(bookID: bookID, quote: quote),
            excerpt: quote,
            note: note,
            createdAt: createdAt
        )
    }

    // MARK: - Persistence

    @Test("annotations survive a new store over the same directory")
    func annotationsSurviveRelaunch() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = ReaderAnnotationStore(libraryRoot: root)
        let saved = try await first.save(
            highlight(quote: "persisted passage")
        )

        // A fresh store models the next cold launch.
        let second = ReaderAnnotationStore(libraryRoot: root)
        let loaded = try await second.annotations(inBook: "book-a")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == saved.id)
        #expect(loaded[0].excerpt == "persisted passage")
        #expect(loaded[0].anchor.cfi == 120)
        // The path and quote must survive too, or the highlight is no longer
        // re-anchorable after a re-extraction.
        #expect(loaded[0].anchor.path == [0, 2, 1])
        #expect(loaded[0].anchor.chapterHref == "OEBPS/Text/ch1.xhtml")
    }

    @Test("updating a mark keeps its identity and creation time")
    func updatePreservesIdentityAndCreation() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        let created = Date(timeIntervalSince1970: 1_000_000)
        let original = try await store.save(
            highlight(quote: "first", createdAt: created)
        )

        var edited = original
        edited.note = "my thought"
        let updated = try await store.save(edited)

        #expect(updated.id == original.id)
        #expect(updated.createdAt == created)
        #expect(updated.updatedAt != created)
        #expect(updated.note == "my thought")

        let all = try await store.annotations(inBook: "book-a")
        #expect(all.count == 1, "an edit must not create a second mark")
    }

    @Test("marks are separated by kind and listed newest first")
    func kindAndOrdering() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        _ = try await store.save(highlight(quote: "older", createdAt: older))
        _ = try await store.save(highlight(quote: "newer", createdAt: newer))
        _ = try await store.save(ReaderAnnotation(
            bookID: "book-a",
            kind: .bookmark,
            anchor: anchor(),
            excerpt: "a bookmark",
            createdAt: newer
        ))

        let highlights = try await store.annotations(inBook: "book-a", kind: .highlight)
        #expect(highlights.map(\.excerpt) == ["newer", "older"])

        let bookmarks = try await store.annotations(inBook: "book-a", kind: .bookmark)
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0].kind == .bookmark)
    }

    @Test("deleting removes only the requested mark")
    func deleteIsScoped() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        let keep = try await store.save(highlight(quote: "keep"))
        let drop = try await store.save(highlight(quote: "drop"))
        try await store.delete(id: drop.id, inBook: "book-a")

        let remaining = try await store.annotations(inBook: "book-a")
        #expect(remaining.map(\.id) == [keep.id])
    }

    // MARK: - Search

    @Test("search is case- and diacritic-insensitive")
    func searchFoldsCaseAndDiacritics() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(quote: "She read her Résumé again"))

        // The reader expects the obvious matches, not a byte compare.
        for query in ["résumé", "Resume", "RÉSUMÉ"] {
            let hits = try await store.search(query: query)
            #expect(hits.count == 1, "expected \(query) to match")
        }
    }

    @Test("search covers the note as well as the excerpt")
    func searchCoversNotes() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(
            quote: "a plain passage",
            note: "compare with the Baha'i chapter"
        ))

        #expect(try await store.search(query: "Baha").count == 1)
        #expect(try await store.search(query: "passage").count == 1)
    }

    @Test("an empty query returns nothing rather than everything")
    func emptyQueryIsNotEverything() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(quote: "something"))

        for query in ["", "   "] {
            #expect(try await store.search(query: query).isEmpty)
        }
    }

    @Test("search can be scoped to one book")
    func searchScope() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(bookID: "book-a", quote: "shared word"))
        _ = try await store.save(highlight(bookID: "book-b", quote: "shared word"))

        #expect(try await store.search(query: "shared").count == 2)
        #expect(try await store.search(query: "shared", inBook: "book-a").count == 1)
    }

    @Test("whitespace in a query matches across line breaks")
    func searchNormalisesWhitespace() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(quote: "a line\nthat   wrapped"))
        #expect(try await store.search(query: "line that wrapped").count == 1)
    }

    // MARK: - Resilience

    @Test("a corrupt file does not lose the books or throw on read")
    func corruptFileIsSurvivable() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(quote: "will be lost"))
        try Data("{ not json".utf8).write(
            to: root.appendingPathComponent("annotations.json")
        )

        // A fresh store over a corrupt file must read as empty rather than
        // propagate a decode error into the reader.
        let reopened = ReaderAnnotationStore(libraryRoot: root)
        #expect(try await reopened.annotations(inBook: "book-a").isEmpty)

        // And it must be writable again, so the reader recovers instead of
        // failing every future mark.
        _ = try await reopened.save(highlight(quote: "after recovery"))
        #expect(try await reopened.annotations(inBook: "book-a").count == 1)
    }

    @Test("books with marks are reported for the library's annotation index")
    func booksWithAnnotations() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderAnnotationStore(libraryRoot: root)
        _ = try await store.save(highlight(bookID: "book-b", quote: "x"))
        _ = try await store.save(highlight(bookID: "book-a", quote: "y"))
        #expect(try await store.allBooksWithAnnotations() == ["book-a", "book-b"])

        try await store.deleteAll(inBook: "book-a")
        #expect(try await store.allBooksWithAnnotations() == ["book-b"])
    }
}
