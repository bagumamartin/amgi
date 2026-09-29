import Foundation

/// Book-wide page numbers for a paginated EPUB.
///
/// The reader paginates by laying the text out in columns, so a chapter's page
/// count is a property of the *rendering* — the font, the size, the page
/// margins, the device. It cannot be read out of the EPUB, and it is not
/// stable: change the type size and every count after it changes too.
///
/// That matters because a reader's page number is only meaningful relative to
/// the whole book. "Page 96 of 4024" is what a reader expects; "page 1 of 5 in
/// this chapter" is not a page number at all. To produce the former we need
/// the count of every chapter before the current one, which means measuring
/// them.
///
/// Measuring a 4000-page book up front would be absurd, so the index is
/// built the way a reader actually moves: the current chapter is known
/// immediately because it is on screen, the chapters either side are measured
/// as they are visited, and the rest are filled in the background at low
/// priority. Until a chapter has been measured the running total is a lower
/// bound, which is reported honestly rather than presented as exact.
public struct ReaderPaginationIndex: Sendable, Equatable {
    /// Rendered page count per chapter index, where present.
    public private(set) var pageCounts: [Int: Int]
    /// Chapters whose count is not yet known.
    public private(set) var unmeasured: [Int]
    /// Total chapters in the book, retained so a measurement for a chapter
    /// that does not exist can be rejected rather than inflating the total.
    public private(set) var knownChapterCount: Int

    public var chapterCount: Int {
        knownChapterCount
    }

    public init(chapterCount: Int) {
        let count = max(0, chapterCount)
        self.knownChapterCount = count
        self.pageCounts = [:]
        self.unmeasured = Array(0..<count)
    }

    public init(pageCounts: [Int: Int], unmeasured: [Int], chapterCount: Int) {
        self.pageCounts = pageCounts
        self.unmeasured = unmeasured
        self.knownChapterCount = max(0, chapterCount)
    }

    public mutating func record(chapter: Int, pageCount: Int) {
        // A chapter index outside the book is a stale caller (the book was
        // re-imported with fewer chapters, or an index from another book was
        // carried over). Accepting it would add pages that do not exist.
        guard chapter >= 0, chapter < knownChapterCount, pageCount >= 0 else { return }
        // A chapter that lays out to no columns — a cover, a divider — still
        // occupies one page in the book. Dropping it instead would make every
        // later page number too small.
        pageCounts[chapter] = max(1, pageCount)
        unmeasured.removeAll { $0 == chapter }
    }

    public func isMeasured(_ chapter: Int) -> Bool {
        pageCounts[chapter] != nil
    }

    public func pageCount(forChapter chapter: Int) -> Int? {
        pageCounts[chapter]
    }

    /// Number of chapters known to sit before `chapter`, whether or not they
    /// have been measured. Used as the running total so a reader who has read
    /// ten chapters sees a monotonically increasing page number.
    public func measuredPages(before chapter: Int) -> Int {
        pageCounts.reduce(into: 0) { total, entry in
            if entry.key < chapter { total += entry.value }
        }
    }

    /// The book's page number for a position, 1-based, and how much of the
    /// total is actually known.
    ///
    /// `isTotalExact` is false while any chapter before `chapter` is
    /// unmeasured, in which case `total` is a lower bound. Callers show that
    /// differently rather than printing a number that will change later.
    public func position(
        chapter: Int,
        pageIndex: Int,
        pageCountInChapter: Int
    ) -> (page: Int, chapterPage: Int, pagesInChapter: Int, total: Int, isTotalExact: Bool) {
        let chapterPage = min(max(0, pageIndex) + 1, max(1, pageCountInChapter))
        let page = measuredPages(before: chapter) + chapterPage
        // Everything measured, plus the current chapter in full: a lower
        // bound on the real total that is at least correct up to here.
        let total = measuredPages(before: max(chapter + 1, chapterCount))
        return (
            page: max(1, page),
            chapterPage: chapterPage,
            pagesInChapter: max(1, pageCountInChapter),
            total: max(1, total),
            isTotalExact: unmeasured.allSatisfy { $0 > chapter }
        )
    }
}

/// Where a measured index is cached.
///
/// Keyed by book *and* by the typography that produced the counts, because a
/// count measured at 17pt is wrong the moment the reader changes the size.
/// Storing it against a fingerprint of the settings that shaped it is what
/// keeps the page number honest across a reading session.
public struct ReaderPaginationCacheKey: Hashable, Sendable, Codable {
    public var bookID: String
    /// Font size, line height, page margin, and font family, rounded — the
    /// inputs that change how much text fits on a page.
    public var typographyFingerprint: String

    public init(bookID: String, typographyFingerprint: String) {
        self.bookID = bookID
        self.typographyFingerprint = typographyFingerprint
    }

    public static func fingerprint(
        fontSizePx: Int,
        lineHeight: Double,
        pageMarginPx: Int,
        fontFamilyCSS: String
    ) -> String {
        // Rounded so a slider that lands on 17.4 and one on 17.6 share a
        // cache entry, but a deliberate jump to 18 does not.
        let size = Int(Double(fontSizePx).rounded())
        let leading = Int((lineHeight * 20).rounded())
        let family = fontFamilyCSS.isEmpty ? "book" : String(fontFamilyCSS.prefix(24))
        return "\(size)-\(leading)-\(pageMarginPx)-\(family)"
    }
}
