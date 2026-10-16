import Foundation
import Testing
@testable import ReaderFeature

/// The rules every turn goes through. A turn that skips a page, stays on one,
/// or lands at the wrong end of a chapter starts here or nowhere.
@Suite("EPUB reading position")
struct EPUBReadingPositionTests {
    /// Cover (1 page), front matter (30), chapter 1 (86).
    private let counts: [Int: Int] = [0: 1, 1: 30, 2: 86]
    private func count(_ chapter: Int) -> Int? { counts[chapter] }
    private func at(_ chapter: Int, _ page: Int) -> EPUBPageAddress { .init(chapter: chapter, page: page) }

    private func next(_ address: EPUBPageAddress) -> EPUBPageAddress? {
        EPUBReadingNavigator.neighbour(of: address, .forward, chapterCount: 3, pageCount: count)
    }

    private func previous(_ address: EPUBPageAddress) -> EPUBPageAddress? {
        EPUBReadingNavigator.neighbour(of: address, .backward, chapterCount: 3, pageCount: count)
    }

    @Test("forward moves exactly one page inside a chapter")
    func forwardInsideChapter() {
        #expect(next(at(1, 5)) == at(1, 6))
    }

    @Test("backward moves exactly one page inside a chapter")
    func backwardInsideChapter() {
        #expect(previous(at(1, 6)) == at(1, 5))
    }

    @Test("forward from a chapter's last page opens the next chapter at its first")
    func forwardCrossesToFirstPage() {
        #expect(next(at(1, 29)) == at(2, 0))
    }

    @Test("backward from a chapter's first page lands on the previous chapter's last")
    func backwardCrossesToLastPage() {
        #expect(previous(at(2, 0)) == at(1, 29))
        #expect(previous(at(1, 0)) == at(0, 0))
    }

    @Test("the cover has no page before it, the last page none after")
    func bookEnds() {
        #expect(previous(at(0, 0)) == nil)
        #expect(next(at(2, 85)) == nil)
    }

    @Test("ten pages forward then ten back returns to the same page")
    func roundTrip() throws {
        var address = at(1, 25)
        var visited: [EPUBPageAddress] = [address]
        for _ in 0..<10 { address = try #require(next(address)); visited.append(address) }
        #expect(address == at(2, 5))
        for _ in 0..<10 { address = try #require(previous(address)) }
        #expect(address == at(1, 25))
        // No page visited twice on the way out, none skipped.
        #expect(Set(visited).count == visited.count)
    }

    @Test("a chapter entered backwards before it is measured resolves once it is")
    func lastPagePlaceholderResolves() {
        let unknown = EPUBReadingNavigator.neighbour(of: at(3, 0), .backward, chapterCount: 4) { $0 == 2 ? nil : counts[$0] }
        #expect(unknown == at(2, EPUBPageAddress.lastPage))
        #expect(EPUBReadingNavigator.resolve(unknown!, pageCount: count) == at(2, 85))
    }

    @Test("an unmeasured chapter is assumed to go on rather than skipped")
    func unmeasuredChapterGoesOn() {
        let reached = EPUBReadingNavigator.neighbour(of: at(2, 3), .forward, chapterCount: 3) { _ in nil }
        #expect(reached == at(2, 4))
    }

    @Test("a page past a chapter that re-flowed shorter is kept inside it")
    func resolveClampsAfterReflow() {
        #expect(EPUBReadingNavigator.resolve(at(1, 40), pageCount: count) == at(1, 29))
    }

    @Test("book-wide numbers only once every chapter is measured")
    func bookPageNumbers() {
        let partial = EPUBReadingNavigator.bookPage(of: at(2, 4), chapterCount: 3, measuredCounts: [2: 86])
        #expect(partial.page == 5 && partial.total == 86 && !partial.isBookWide)
        let full = EPUBReadingNavigator.bookPage(of: at(2, 4), chapterCount: 3, measuredCounts: counts)
        #expect(full.page == 1 + 30 + 5 && full.total == 117 && full.isBookWide)
    }

    @Test("fractions restore to the page they were saved from")
    func fractionRoundTrip() {
        for page in [0, 1, 29, 57, 85] {
            let fraction = EPUBReadingNavigator.fraction(ofPage: page, pageCount: 86)
            #expect(EPUBReadingNavigator.page(forFraction: fraction, pageCount: 86) == page)
        }
        #expect(EPUBReadingNavigator.page(forFraction: .nan, pageCount: 10) == 0)
    }

    @Test("a page state decodes from the page script's result")
    func pageStateDecodes() {
        let state = EPUBPageState(scriptResult: ["page": 3, "count": 30, "first": 1200, "last": 1840] as [String: Any])
        #expect(state == EPUBPageState(page: 3, pageCount: 30, firstOffset: 1200, lastOffset: 1840))
        #expect(EPUBPageState(scriptResult: nil) == nil)
    }
}
