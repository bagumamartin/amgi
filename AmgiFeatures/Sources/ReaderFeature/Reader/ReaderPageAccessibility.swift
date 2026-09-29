import Foundation

/// Shared, testable accessibility strings and announcements for the paged
/// reader.
///
/// The paging state is shared by both platform hosts, so the wording and the
/// "did the page actually change" debounce live here rather than being
/// reimplemented per host.
enum ReaderPageAccessibility {
    /// Spoken form of the page counter.
    static func pageLabel(pageIndex: Int, pageCount: Int) -> String {
        let index = max(1, pageIndex + 1)
        let count = max(1, pageCount)
        return "Page \(index) of \(count)"
    }

    /// Announced after a turn. Kept short — a long sentence interrupts
    /// reading, and the reader user is usually mid-sentence.
    static func pageTurnAnnouncement(pageIndex: Int, pageCount: Int) -> String {
        "\(pageLabel(pageIndex: pageIndex, pageCount: pageCount))"
    }

    /// Whether a page change is worth announcing.
    ///
    /// Skips the very first report (there is nothing to compare against) and
    /// repeats of the same index, which is what a bouncing scroll view
    /// produces when a turn is cancelled at the edge.
    static func shouldAnnounce(
        previous: Int?,
        current: Int,
        pageCount: Int
    ) -> Bool {
        guard let previous else { return false }
        guard previous != current else { return false }
        // At the end of a chapter the host switches documents; the count
        // resets and "page 1 of 1" is announced by the new chapter itself.
        return max(1, pageCount) > 1
    }
}
