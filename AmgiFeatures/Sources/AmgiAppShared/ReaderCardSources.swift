import AmgiAppCore
import AmgiReader
import AnkiClients
import Dependencies
package import Foundation
import Observation

/// Where a note made while reading came from: its book, the chapter, and the
/// card mark holding the passage. The reader records each card as a `.card`
/// annotation whose note is `nid:<id>`; this reads them back so Browse can
/// group notes by book and open the passage, without importing the reader.
package struct ReaderCardLink: Sendable, Hashable {
    package let bookID: String
    package let bookTitle: String
    package let chapterID: Int64?
    package let annotationID: UUID
    package let excerpt: String
}

/// A book that has cards made from it.
package struct ReaderCardBook: Sendable, Hashable, Identifiable {
    package let id: String
    package let title: String
    package let noteIDs: [Int64]
}

package enum ReaderCardSources {
    /// Every reader-made note's link, keyed by note id, plus the books in
    /// title order. Reads the profile's annotation file and the library's
    /// titles; nothing here touches the collection.
    @MainActor
    package static func load() async -> (links: [Int64: ReaderCardLink], books: [ReaderCardBook]) {
        @Dependency(\.epubLibraryClient) var epub
        @Dependency(\.pdfLibraryClient) var pdf
        let store = ReaderAnnotationStore(
            libraryRoot: AccountStore.profileDirectory(for: AccountStore.shared.selectedID)
                .appendingPathComponent("EPUB", isDirectory: true)
        )
        guard let bookIDs = try? await store.allBooksWithAnnotations(), !bookIDs.isEmpty else {
            return ([:], [])
        }
        let titles = Dictionary(
            (await epub.listBooks() + pdf.listBooks()).map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        var links: [Int64: ReaderCardLink] = [:]
        var books: [ReaderCardBook] = []
        for bookID in bookIDs {
            guard let marks = try? await store.annotations(inBook: bookID, kind: .card) else { continue }
            let title = titles[bookID] ?? "Untitled Book"
            var noteIDs: [Int64] = []
            for mark in marks {
                guard let note = mark.note, note.hasPrefix("nid:"),
                      let noteID = Int64(note.dropFirst(4)) else { continue }
                noteIDs.append(noteID)
                links[noteID] = ReaderCardLink(
                    bookID: bookID,
                    bookTitle: title,
                    chapterID: mark.anchor.chapterID,
                    annotationID: mark.id,
                    excerpt: mark.excerpt
                )
            }
            if !noteIDs.isEmpty {
                books.append(ReaderCardBook(id: bookID, title: title, noteIDs: noteIDs))
            }
        }
        books.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (links, books)
    }
}

/// Asks the reader to open a book at a card's passage. Browse submits; the
/// composition root switches to the Read tab and the library consumes it —
/// the same hand-off `ReaderImportRequestRouter` uses for dropped files.
@Observable
@MainActor
package final class ReaderOpenRequestRouter {
    package static let shared = ReaderOpenRequestRouter()

    package struct Request: Identifiable, Equatable, Sendable {
        package let id = UUID()
        package let bookID: String
        package let annotationID: UUID
        package let profileID: String
    }

    package private(set) var pending: Request?

    private init() {}

    package func request(_ link: ReaderCardLink) {
        pending = Request(
            bookID: link.bookID,
            annotationID: link.annotationID,
            profileID: AccountStore.shared.selectedID
        )
    }

    package func consume(profileID: String) -> Request? {
        guard let pending, pending.profileID == profileID else { return nil }
        self.pending = nil
        return pending
    }
}
