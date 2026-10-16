import Foundation

/// Where a page is in the book: a chapter (spine document) and a page within
/// it.
///
/// This is the one place the reader's position lives. Every turn, jump,
/// restore and bookmark moves it, and everything on screen — the live page,
/// the pictures the curl turns, the page counter — is derived from it. Nothing
/// reads a position back from a scroll offset: a page is shown by telling the
/// chapter to show it, and the chapter confirms what it actually shows (see
/// `EPUBPageState`).
struct EPUBPageAddress: Hashable, Sendable, CustomStringConvertible {
    let chapter: Int
    /// Zero-based. `-1` means "the last page", for a chapter entered
    /// backwards before its page count is known.
    var page: Int

    var description: String { "c\(chapter)p\(page)" }

    static let lastPage = -1
}

/// What a chapter reports it is actually showing, read from the page itself
/// after it has painted. Used to check that the page on screen is the page
/// asked for, and that a picture of a page matches the live page.
struct EPUBPageState: Equatable, Sendable {
    let page: Int
    let pageCount: Int
    /// Chapter-text offsets of the first and last characters visible on the
    /// page. Nil when the page shows no text (an image, a blank page).
    let firstOffset: Int?
    let lastOffset: Int?

    init(page: Int, pageCount: Int, firstOffset: Int?, lastOffset: Int?) {
        self.page = page
        self.pageCount = pageCount
        self.firstOffset = firstOffset
        self.lastOffset = lastOffset
    }

    /// Decodes the dictionary `__amgiShowPage` / `__amgiPageState` return.
    init?(scriptResult: Any?) {
        guard let dict = scriptResult as? [String: Any],
              let page = (dict["page"] as? NSNumber)?.intValue,
              let count = (dict["count"] as? NSNumber)?.intValue else { return nil }
        self.init(
            page: page,
            pageCount: max(1, count),
            firstOffset: (dict["first"] as? NSNumber)?.intValue,
            lastOffset: (dict["last"] as? NSNumber)?.intValue
        )
    }
}

/// The rules for moving through the book, with no UI in them. Unit-tested in
/// `EPUBReadingPositionTests`.
enum EPUBReadingNavigator {
    /// The page a turn in `direction` reaches from `address`, or nil at the
    /// start or end of the book.
    ///
    /// - Parameter pageCount: a chapter's page count at the current layout,
    ///   when known. A chapter whose count is not known yet is assumed to go
    ///   on, so a turn never skips the rest of it.
    static func neighbour(
        of address: EPUBPageAddress,
        _ direction: ReaderPageDirection,
        chapterCount: Int,
        pageCount: (Int) -> Int?
    ) -> EPUBPageAddress? {
        let address = resolve(address, pageCount: pageCount)
        switch direction {
        case .forward:
            if address.page < 0 {
                // The last page of a chapter whose length is still unknown:
                // the next page is the next chapter.
                return address.chapter + 1 < chapterCount
                    ? EPUBPageAddress(chapter: address.chapter + 1, page: 0) : nil
            }
            if let count = pageCount(address.chapter) {
                if address.page + 1 < count {
                    return EPUBPageAddress(chapter: address.chapter, page: address.page + 1)
                }
                return address.chapter + 1 < chapterCount
                    ? EPUBPageAddress(chapter: address.chapter + 1, page: 0) : nil
            }
            return EPUBPageAddress(chapter: address.chapter, page: address.page + 1)
        case .backward:
            if address.page > 0 {
                return EPUBPageAddress(chapter: address.chapter, page: address.page - 1)
            }
            guard address.chapter > 0 else { return nil }
            return resolve(
                EPUBPageAddress(chapter: address.chapter - 1, page: EPUBPageAddress.lastPage),
                pageCount: pageCount
            )
        }
    }

    /// Replaces "the last page" with the real index once the chapter's count
    /// is known, and keeps any page inside the chapter it names — a re-flow
    /// can make a chapter shorter than the page the reader was on.
    static func resolve(_ address: EPUBPageAddress, pageCount: (Int) -> Int?) -> EPUBPageAddress {
        guard let count = pageCount(address.chapter) else { return address }
        let last = max(0, count - 1)
        if address.page < 0 { return EPUBPageAddress(chapter: address.chapter, page: last) }
        return EPUBPageAddress(chapter: address.chapter, page: min(address.page, last))
    }

    /// The page's number in the whole book, and the book's total — only when
    /// every chapter has been measured, because a book-wide number that moves
    /// as chapters are measured reads as a bug. Otherwise the number within
    /// the chapter.
    static func bookPage(
        of address: EPUBPageAddress,
        chapterCount: Int,
        measuredCounts: [Int: Int]
    ) -> (page: Int, total: Int, isBookWide: Bool) {
        let page = max(0, address.page)
        let counts = (0..<chapterCount).map { measuredCounts[$0] }
        guard chapterCount > 0, counts.allSatisfy({ $0 != nil }) else {
            let chapterTotal = measuredCounts[address.chapter] ?? (page + 1)
            return (page + 1, max(1, chapterTotal), false)
        }
        let known = counts.map { max(1, $0 ?? 1) }
        let before = known.prefix(max(0, min(address.chapter, known.count))).reduce(0, +)
        return (before + page + 1, max(1, known.reduce(0, +)), true)
    }

    /// The page a saved fraction of a chapter restores to.
    static func page(forFraction fraction: Double, pageCount: Int) -> Int {
        let last = max(0, pageCount - 1)
        guard fraction.isFinite else { return 0 }
        return min(last, max(0, Int((min(1, max(0, fraction)) * Double(last)).rounded())))
    }

    /// The fraction of a chapter a page is at, for saving progress.
    static func fraction(ofPage page: Int, pageCount: Int) -> Double {
        pageCount <= 1 ? 1 : min(1, max(0, Double(page) / Double(pageCount - 1)))
    }
}
