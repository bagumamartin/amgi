import Foundation

/// Which outline entry the reader is "in", for the Contents list's checkmark.
enum PDFContentsPosition {
    /// The entry the current page belongs to: the one starting nearest before
    /// or on `page`. On a tie — a chapter and its first section starting on
    /// the same page — the later entry in outline order wins, which is the
    /// deeper, more specific one. Entries that resolve to no page never match.
    ///
    /// Before the first entry (a cover, front matter outside the outline)
    /// nothing is current: marking the first chapter there would claim the
    /// reader is somewhere they are not.
    static func currentEntryID(in bookmarks: [PDFBookmark], page: Int) -> String? {
        var best: PDFBookmark?
        for bookmark in bookmarks where bookmark.hasDestination && bookmark.pageIndex <= page {
            if bookmark.pageIndex >= (best?.pageIndex ?? .min) {
                best = bookmark
            }
        }
        return best?.id
    }
}
