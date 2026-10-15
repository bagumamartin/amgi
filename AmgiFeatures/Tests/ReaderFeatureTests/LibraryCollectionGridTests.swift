import AmgiReader
import Foundation
import Testing
@testable import ReaderFeature

/// The library grid with collections: a level shows its collections first,
/// then only the books filed there; search ignores folders entirely.
@Suite("Library collection grid")
struct LibraryCollectionGridTests {
    private func cell(_ id: String) -> BookCellItem {
        BookCellItem(id: id, title: id, author: nil, surname: nil, coverArt: .none, repair: nil)
    }

    @Test("a level shows its collections first, then only its own books")
    func levelScoping() {
        var tree = ReaderCollectionTree()
        let shelf = tree.createCollection(named: "Shelf", in: nil)
        let nested = tree.createCollection(named: "Nested", in: shelf)
        tree.move(.book("filed"), to: shelf)
        tree.move(.book("deep"), to: nested)
        let cells = ["loose", "filed", "deep"].map(cell)

        let top = ReaderLibraryViewDataBuilder.grid(cells: cells, collections: tree, in: nil)
        #expect(top.map(\.ref) == [.collection(shelf), .book("loose")])

        guard case .collection(let shelfCell) = top.first else {
            Issue.record("expected the collection first")
            return
        }
        #expect(shelfCell.bookCount == 2)
        #expect(shelfCell.collectionCount == 1)
        #expect(shelfCell.covers.map(\.id) == ["filed", "deep"])

        let inside = ReaderLibraryViewDataBuilder.grid(cells: cells, collections: tree, in: shelf)
        #expect(inside.map(\.ref) == [.collection(nested), .book("filed")])
    }

    @Test("search shows every match, filed or not, plus matching collections")
    func searchIgnoresFolders() {
        var tree = ReaderCollectionTree()
        let shelf = tree.createCollection(named: "Physics", in: nil)
        tree.move(.book("filed"), to: shelf)

        let grid = ReaderLibraryViewDataBuilder.grid(
            cells: [cell("filed")],
            collections: tree,
            in: nil,
            matching: "phys"
        )
        #expect(grid.map(\.ref) == [.collection(shelf), .book("filed")])
    }

    @Test("Remove from Continue hides a book until it is read again")
    func removeFromContinue() {
        let book = ReaderBook(id: "b1", title: "Book", author: nil, chapters: [])
        func continueIDs(readAt: Date, hiddenAt: Date?) -> [String] {
            ReaderLibraryViewDataBuilder.build(
                books: [book],
                progressFor: { _ in ReaderSavedProgress(chapterID: 0, progress: 0.4, updatedAt: readAt) },
                epubCoverURLFor: { _ in nil },
                continueHiddenAt: { _ in hiddenAt },
                searchText: "",
                sortMode: .recent,
                hasAnkiConfig: false
            ).continueReading.map(\.id)
        }
        let read = Date(timeIntervalSince1970: 1_000)
        #expect(continueIDs(readAt: read, hiddenAt: nil) == ["b1"])
        #expect(continueIDs(readAt: read, hiddenAt: read.addingTimeInterval(10)).isEmpty)
        #expect(continueIDs(readAt: read.addingTimeInterval(20), hiddenAt: read.addingTimeInterval(10)) == ["b1"])
    }
}
