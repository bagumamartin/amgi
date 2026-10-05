import AmgiReader
import AmgiReaderEPUB
import Foundation
import Testing
@testable import ReaderFeature

/// Library-row behaviour around unreadable books. The regression these lock
/// down: a book whose source went missing used to vanish from the list with no
/// trace, because `books()` dropped it whenever a rebuild returned nil.
@Suite("EPUB library view data")
struct ReaderLibraryViewDataTests {
    private func book(_ id: String, title: String = "Book") -> ReaderBook {
        ReaderBook(
            id: id,
            title: title,
            author: "Author",
            chapters: [],
            source: .epub(localURL: URL(fileURLWithPath: "/tmp/\(id).epub"))
        )
    }

    private func build(
        books: [ReaderBook],
        repairIDs: Set<String> = [],
        progress: [String: ReaderSavedProgress] = [:],
        sortMode: BookshelfSortMode = .title,
        searchText: String = ""
    ) -> ReaderLibraryViewData {
        ReaderLibraryViewDataBuilder.build(
            books: books,
            progressFor: { progress[$0] },
            epubCoverURLFor: { _ in nil },
            repairFor: { repairIDs.contains($0)
                ? ReaderBookRepair(fault: .sourceMissing, detail: "gone")
                : nil
            },
            searchText: searchText,
            sortMode: sortMode,
            hasAnkiConfig: true
        )
    }

    @Test("a book needing repair still occupies a row")
    func repairedBookStillListed() {
        let data = build(
            books: [book("a", title: "Readable"), book("b", title: "Broken")],
            repairIDs: ["b"]
        )
        #expect(data.allBooks.count == 2)
        #expect(data.allBooks.map(\.id).sorted() == ["a", "b"])
        #expect(data.allBooks.first(where: { $0.id == "b" })?.repair?.fault == .sourceMissing)
        #expect(data.allBooks.first(where: { $0.id == "a" })?.repair == nil)
    }

    @Test("a book needing repair is kept out of continue reading")
    func repairedBookNotResumable() {
        let data = build(
            books: [book("broken", title: "Broken")],
            repairIDs: ["broken"],
            progress: ["broken": ReaderSavedProgress(chapterID: 1, progress: 0.5, updatedAt: .now)]
        )
        #expect(data.continueReading.isEmpty)
    }

    @Test("books needing repair sort last in every sort mode")
    func repairedBooksSortLast() {
        for mode in [BookshelfSortMode.title, .recent, .progress] {
            let data = build(
                books: [book("aaa", title: "Broken"), book("zzz", title: "Readable")],
                repairIDs: ["aaa"],
                progress: ["zzz": ReaderSavedProgress(chapterID: 1, progress: 0.9, updatedAt: .now)],
                sortMode: mode
            )
            #expect(
                data.allBooks.last?.id == "aaa",
                "expected the broken book last in \(mode)"
            )
        }
    }

    @Test("a repairable book is still findable by search")
    func repairedBookIsSearchable() {
        let data = build(
            books: [book("a", title: "Readable"), book("b", title: "Broken")],
            repairIDs: ["b"],
            searchText: "Broken"
        )
        #expect(data.allBooks.map(\.id) == ["b"])
    }

    @Test("the repair message falls back when the detail is blank")
    func repairMessageFallsBack() {
        let blank = ReaderBookRepair(fault: .parseFailed, detail: "   ")
        #expect(blank.message.contains("could not be opened"))

        let detailed = ReaderBookRepair(fault: .parseFailed, detail: "Bad zip header")
        #expect(detailed.message == "Bad zip header")
    }

    @Test("only a missing source rules out an in-place retry")
    func retryAvailability() {
        #expect(ReaderBookRepair(fault: .parseFailed, detail: nil).canRetryInPlace)
        #expect(ReaderBookRepair(fault: .sourceUnreadable, detail: nil).canRetryInPlace)
        #expect(ReaderBookRepair(fault: .sourceMissing, detail: nil).canRetryInPlace == false)
    }

    @Test("a coverless EPUB renders its first page before the placeholder")
    func coverlessEPUBUsesFirstPage() {
        let firstPage = EPUBFirstPageSource(
            contentURL: URL(fileURLWithPath: "/tmp/ch1.html"),
            readAccessURL: URL(fileURLWithPath: "/tmp/")
        )
        let data = ReaderLibraryViewDataBuilder.build(
            books: [book("a")],
            progressFor: { _ in nil },
            epubCoverURLFor: { _ in nil },
            epubFirstPageFor: { _ in firstPage },
            searchText: "",
            sortMode: .title,
            hasAnkiConfig: true
        )
        #expect(data.allBooks.first?.coverArt == .epubFirstPage(firstPage))
    }

    @Test("an embedded cover wins over the first page")
    func embeddedCoverWinsOverFirstPage() {
        let cover = URL(fileURLWithPath: "/tmp/cover.jpg")
        let firstPage = EPUBFirstPageSource(
            contentURL: URL(fileURLWithPath: "/tmp/ch1.html"),
            readAccessURL: URL(fileURLWithPath: "/tmp/")
        )
        let data = ReaderLibraryViewDataBuilder.build(
            books: [book("a")],
            progressFor: { _ in nil },
            epubCoverURLFor: { _ in cover },
            epubFirstPageFor: { _ in firstPage },
            searchText: "",
            sortMode: .title,
            hasAnkiConfig: true
        )
        #expect(data.allBooks.first?.coverArt == .epub(localFileURL: cover))
    }
}
