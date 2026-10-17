import Testing
@testable import ReaderFeature

/// The back-through-history counter counts jumps, not page turns. Recording
/// every turn made the counter climb on each swipe, and "back" stepped one
/// page at a time instead of returning to where the reader leapt from.
@Suite("Reader reading history")
struct ReaderReadingHistoryTests {
    private func at(_ chapter: Int, _ page: Int) -> ReaderReadingPosition {
        ReaderReadingPosition(chapterIndex: chapter, pageIndex: page)
    }

    private let counts: [Int: Int] = [2: 86, 3: 252]

    @Test("Next and previous page in a chapter are turns")
    func turnsInsideChapter() {
        #expect(at(2, 41).isTurn(from: at(2, 40)) { counts[$0] })
        #expect(at(2, 39).isTurn(from: at(2, 40)) { counts[$0] })
    }

    @Test("Crossing a chapter boundary page by page is a turn")
    func turnsAcrossChapters() {
        #expect(at(3, 0).isTurn(from: at(2, 85)) { counts[$0] })
        #expect(at(2, 85).isTurn(from: at(3, 0)) { counts[$0] })
    }

    @Test("Leaving a chapter from anywhere but its edge is a jump")
    func chapterJumpsAreJumps() {
        #expect(!at(3, 0).isTurn(from: at(2, 10)) { counts[$0] })
        #expect(!at(2, 85).isTurn(from: at(3, 5)) { counts[$0] })
        #expect(!at(5, 0).isTurn(from: at(2, 85)) { counts[$0] })
    }

    @Test("Moving more than a page inside a chapter is a jump")
    func pageJumpsAreJumps() {
        #expect(!at(2, 60).isTurn(from: at(2, 40)) { counts[$0] })
    }
}
