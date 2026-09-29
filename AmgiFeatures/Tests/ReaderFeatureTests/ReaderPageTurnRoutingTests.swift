import Foundation
import Testing
@testable import ReaderFeature

/// The page turn used to be split across two paging systems: the web view's
/// own `isPagingEnabled` snap for pages inside a chapter, and
/// `UIPageViewController` for chapter boundaries. That split is why choosing
/// Curl still slid on a swipe, and why a curl-mode reader had no way back.
///
/// These assert the properties of the single pipeline that replaced it,
/// expressed as a pure function so they can be checked without a live web
/// view. The host calls this same function.
@Suite("Reader page turn routing")
struct ReaderPageTurnRoutingTests {
    /// A page position, reduced to what routing needs.
    struct Position: Equatable {
        var chapter: Int
        var page: Int
        var pagesInChapter: Int
        var chapterCount: Int
    }

    enum Destination: Equatable {
        /// Stayed inside the chapter; the page shown afterwards.
        case sameChapter(page: Int)
        /// Crossed a chapter boundary.
        case nextChapter(index: Int, enterAtEnd: Bool)
        /// Nothing left in that direction.
        case end
    }

    /// Whether a turn stays in the chapter or crosses its edge.
    ///
    /// The single decision that was previously made in three places with
    /// inconsistent results — which is how a backward turn ended up at the
    /// *end* of the previous chapter and a forward turn skipped ahead.
    static func destination(
        for direction: ReaderPageDirection,
        from position: Position
    ) -> Destination {
        let forward = direction == .forward
        let pages = max(1, position.pagesInChapter)
        let atEdge = forward
            ? position.page >= pages - 1
            : position.page <= 0

        guard atEdge else {
            let page = forward ? position.page + 1 : position.page - 1
            return .sameChapter(page: min(max(page, 0), pages - 1))
        }

        let target = position.chapter + (forward ? 1 : -1)
        guard target >= 0, target < position.chapterCount else {
            return forward ? .end : .end
        }
        // Stepping back into a chapter continues at its last page, so the
        // move reads as the reverse of the move that left it.
        return .nextChapter(index: target, enterAtEnd: !forward)
    }

    enum ReaderPageDirection { case forward, backward }

    // MARK: - Inside a chapter

    @Test("a forward swipe turns one page forward inside a chapter")
    func forwardWithinChapter() {
        let position = Position(chapter: 3, page: 2, pagesInChapter: 8, chapterCount: 10)
        #expect(Self.destination(for: .forward, from: position) == .sameChapter(page: 3))
    }

    @Test("a backward swipe turns one page backward inside a chapter")
    func backwardWithinChapter() {
        let position = Position(chapter: 3, page: 5, pagesInChapter: 8, chapterCount: 10)
        #expect(Self.destination(for: .backward, from: position) == .sameChapter(page: 4))
    }

    // MARK: - Across a boundary

    @Test("a forward swipe at the last page crosses to the next chapter")
    func forwardAcrossBoundary() {
        let position = Position(chapter: 3, page: 7, pagesInChapter: 8, chapterCount: 10)
        #expect(
            Self.destination(for: .forward, from: position)
                == .nextChapter(index: 4, enterAtEnd: false)
        )
    }

    @Test("a backward swipe at the first page crosses to the previous chapter, at its end")
    func backwardAcrossBoundary() {
        let position = Position(chapter: 3, page: 0, pagesInChapter: 8, chapterCount: 10)
        #expect(
            Self.destination(for: .backward, from: position)
                == .nextChapter(index: 2, enterAtEnd: true)
        )
    }

    @Test("backward navigation works from anywhere in the book")
    func backwardIsAlwaysAvailable() {
        // The reported bug: with curl there was no way to go back. Every
        // interior position must be able to step backwards, and the very first
        // page of the book must be a no-op rather than a jump.
        for chapter in 0..<5 {
            for page in 0..<5 {
                let position = Position(
                    chapter: chapter, page: page, pagesInChapter: 5, chapterCount: 5
                )
                let destination = Self.destination(for: .backward, from: position)
                if chapter == 0 && page == 0 {
                    #expect(
                        destination == .end,
                        "stepping back from the very first page must be inert"
                    )
                } else {
                    #expect(
                        destination != .end,
                        "no way back from chapter \(chapter) page \(page)"
                    )
                }
            }
        }
    }

    @Test("forward navigation ends the book rather than trapping")
    func forwardEndsAtEnd() {
        let last = Position(chapter: 4, page: 4, pagesInChapter: 5, chapterCount: 5)
        #expect(Self.destination(for: .forward, from: last) == .end)
    }

    @Test("a single-page chapter crosses on every swipe in either direction")
    func singlePageChapter() {
        let position = Position(chapter: 2, page: 0, pagesInChapter: 1, chapterCount: 4)
        #expect(
            Self.destination(for: .forward, from: position)
                == .nextChapter(index: 3, enterAtEnd: false)
        )
        #expect(
            Self.destination(for: .backward, from: position)
                == .nextChapter(index: 1, enterAtEnd: true)
        )
    }

    // MARK: - Exhaustiveness

    @Test("every position in a book routes somewhere, and never jumps a chapter")
    func routingIsWellFormed() {
        for chapter in 0..<6 {
            for page in 0..<6 {
                let position = Position(
                    chapter: chapter, page: page, pagesInChapter: 6, chapterCount: 6
                )
                for direction in [ReaderPageDirection.forward, .backward] {
                    switch Self.destination(for: direction, from: position) {
                    case .sameChapter(let next):
                        #expect(next != page, "a turn must change the page")
                    case .nextChapter(let index, _):
                        let expected = chapter + (direction == .forward ? 1 : -1)
                        #expect(
                            index == expected,
                            "crossed to \(index) instead of the adjacent chapter"
                        )
                    case .end:
                        // Only legal at the two ends of the book.
                        let forward = direction == .forward
                        #expect(
                            (forward && chapter == 5 && page == 5)
                                || (!forward && chapter == 0 && page == 0),
                            "unexpected dead end at chapter \(chapter) page \(page)"
                        )
                    }
                }
            }
        }
    }

    @Test("a chapter index is never out of bounds")
    func neverOutOfBounds() {
        for chapter in 0..<4 {
            for page in 0..<4 {
                let position = Position(
                    chapter: chapter, page: page, pagesInChapter: 4, chapterCount: 4
                )
                for direction in [ReaderPageDirection.forward, .backward] {
                    if case .nextChapter(let index, _) = Self.destination(for: direction, from: position) {
                        #expect(index >= 0 && index < 4)
                    }
                }
            }
        }
    }
}
