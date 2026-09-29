import Foundation
import Testing
@testable import ReaderFeature

/// A reader's page number is only meaningful relative to the whole book.
/// These cover the running total that makes "page 96" mean something, and in
/// particular the honesty requirement: while chapters are still unmeasured the
/// total is a lower bound, and the index has to say so rather than present a
/// number that will change under the reader.
@Suite("Reader pagination index")
struct ReaderPaginationIndexTests {
    @Test("the first page of the first chapter is page 1")
    func firstPageOfBook() {
        var index = ReaderPaginationIndex(chapterCount: 3)
        index.record(chapter: 0, pageCount: 10)
        let position = index.position(chapter: 0, pageIndex: 0, pageCountInChapter: 10)
        #expect(position.page == 1)
        #expect(position.chapterPage == 1)
    }

    @Test("the second chapter's first page follows the first chapter's last")
    func pageNumbersRunContinuously() {
        var index = ReaderPaginationIndex(chapterCount: 3)
        index.record(chapter: 0, pageCount: 10)
        index.record(chapter: 1, pageCount: 5)
        // Chapter 1 is 10 pages, so its first page is book page 11 — not 1.
        #expect(
            index.position(chapter: 1, pageIndex: 0, pageCountInChapter: 5).page == 11
        )
        #expect(
            index.position(chapter: 1, pageIndex: 4, pageCountInChapter: 5).page == 15
        )
    }

    @Test("an unmeasured earlier chapter makes the total a lower bound")
    func unmeasuredChaptersLowerTheBound() {
        var index = ReaderPaginationIndex(chapterCount: 4)
        index.record(chapter: 2, pageCount: 8)
        let position = index.position(chapter: 2, pageIndex: 0, pageCountInChapter: 8)
        // Nothing before chapter 2 is known, so the total cannot be exact.
        #expect(position.isTotalExact == false)
        // But the page within the chapter is still right.
        #expect(position.page == 1)
    }

    @Test("the total becomes exact once every earlier chapter is measured")
    func totalBecomesExact() {
        var index = ReaderPaginationIndex(chapterCount: 3)
        index.record(chapter: 0, pageCount: 10)
        index.record(chapter: 1, pageCount: 5)
        let position = index.position(chapter: 1, pageIndex: 0, pageCountInChapter: 5)
        #expect(position.isTotalExact == true)
        #expect(position.total == 15)
    }

    @Test("a chapter after the current one does not affect its page number")
    func laterChaptersDoNotShift() {
        var index = ReaderPaginationIndex(chapterCount: 4)
        index.record(chapter: 0, pageCount: 10)
        let before = index.position(chapter: 0, pageIndex: 2, pageCountInChapter: 10)
        index.record(chapter: 3, pageCount: 99)
        let after = index.position(chapter: 0, pageIndex: 2, pageCountInChapter: 10)
        #expect(before.page == after.page)
    }

    @Test("a chapter with no content still occupies one page")
    func emptyChapterStillOccupiesAPage() {
        var index = ReaderPaginationIndex(chapterCount: 2)
        // A measure that returns 0 must not make later page numbers go
        // backwards.
        index.record(chapter: 0, pageCount: 0)
        #expect(index.pageCount(forChapter: 0) == 1)
        index.record(chapter: 1, pageCount: 4)
        #expect(index.position(chapter: 1, pageIndex: 0, pageCountInChapter: 4).page == 2)
    }

    @Test("re-measuring a chapter replaces its count rather than adding to it")
    func remeasureReplaces() {
        var index = ReaderPaginationIndex(chapterCount: 2)
        index.record(chapter: 0, pageCount: 10)
        // Reading the same chapter again after a rotation must not double it.
        index.record(chapter: 0, pageCount: 12)
        #expect(index.pageCount(forChapter: 0) == 12)
        #expect(index.position(chapter: 1, pageIndex: 0, pageCountInChapter: 3).page == 13)
    }

    @Test("out-of-range measurements are ignored")
    func invalidMeasurementsIgnored() {
        var index = ReaderPaginationIndex(chapterCount: 2)
        index.record(chapter: -1, pageCount: 5)
        index.record(chapter: 99, pageCount: 5)
        index.record(chapter: 0, pageCount: -3)
        #expect(index.pageCounts.isEmpty)
        #expect(index.unmeasured == [0, 1])
    }

    @Test("an out-of-range page index is clamped into the chapter")
    func pageIndexIsClamped() {
        var index = ReaderPaginationIndex(chapterCount: 1)
        index.record(chapter: 0, pageCount: 5)
        // A stale offset reporting page 99 must not produce page 99.
        #expect(index.position(chapter: 0, pageIndex: 99, pageCountInChapter: 5).chapterPage == 5)
        #expect(index.position(chapter: 0, pageIndex: -4, pageCountInChapter: 5).chapterPage == 1)
    }

    @Test("book position is never reported as less than one")
    func neverBelowOne() {
        var index = ReaderPaginationIndex(chapterCount: 0)
        let position = index.position(chapter: 0, pageIndex: 0, pageCountInChapter: 0)
        #expect(position.page >= 1)
        #expect(position.total >= 1)
    }

    @Test("a measured chapter is no longer reported as unmeasured")
    func measurementIsIdempotent() {
        var index = ReaderPaginationIndex(chapterCount: 3)
        #expect(index.unmeasured == [0, 1, 2])
        index.record(chapter: 1, pageCount: 4)
        #expect(index.unmeasured == [0, 2])
        index.record(chapter: 1, pageCount: 4)
        #expect(index.unmeasured == [0, 2])
        #expect(index.isMeasured(1))
        #expect(index.isMeasured(0) == false)
    }

    @Test("the chapter count survives partial measurement")
    func chapterCountIsStable() {
        var index = ReaderPaginationIndex(chapterCount: 12)
        index.record(chapter: 3, pageCount: 7)
        #expect(index.chapterCount == 12)
    }
}

@Suite("Reader pagination cache key")
struct ReaderPaginationCacheKeyTests {
    @Test("a different type size invalidates the counts")
    func sizeChangesKey() {
        let a = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: ""
        )
        let b = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 19, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: ""
        )
        #expect(a != b)
    }

    @Test("a different leading invalidates the counts")
    func lineHeightChangesKey() {
        let a = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: ""
        )
        let b = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.8, pageMarginPx: 24, fontFamilyCSS: ""
        )
        #expect(a != b)
    }

    @Test("a different page margin invalidates the counts")
    func marginChangesKey() {
        let a = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: ""
        )
        let b = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 40, fontFamilyCSS: ""
        )
        #expect(a != b)
    }

    @Test("the book's own font is a distinct key from an explicit one")
    func bookFontIsDistinct() {
        let book = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: ""
        )
        let serif = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: "Georgia, serif"
        )
        #expect(book != serif)
    }

    @Test("the same settings produce the same key")
    func stableKey() {
        let a = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: "Georgia"
        )
        let b = ReaderPaginationCacheKey.fingerprint(
            fontSizePx: 17, lineHeight: 1.55, pageMarginPx: 24, fontFamilyCSS: "Georgia"
        )
        #expect(a == b)
    }
}
