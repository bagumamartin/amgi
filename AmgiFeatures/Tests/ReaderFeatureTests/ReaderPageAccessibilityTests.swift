import Foundation
import Testing
@testable import ReaderFeature

@Suite("EPUB reader page accessibility")
struct ReaderPageAccessibilityTests {
    @Test("the page label names what it is and is 1-based")
    func pageLabelIsOneBased() {
        #expect(ReaderPageAccessibility.pageLabel(pageIndex: 0, pageCount: 12) == "Page 1 of 12")
        #expect(ReaderPageAccessibility.pageLabel(pageIndex: 11, pageCount: 12) == "Page 12 of 12")
    }

    @Test("degenerate counts and indices do not produce nonsense")
    func pageLabelClamps() {
        #expect(ReaderPageAccessibility.pageLabel(pageIndex: 0, pageCount: 0) == "Page 1 of 1")
        #expect(ReaderPageAccessibility.pageLabel(pageIndex: -1, pageCount: 5) == "Page 1 of 5")
    }

    @Test("the first page report is not announced")
    func firstReportIsSilent() {
        #expect(
            ReaderPageAccessibility.shouldAnnounce(
                previous: nil,
                current: 0,
                pageCount: 12
            ) == false
        )
    }

    @Test("a real turn is announced")
    func realTurnAnnounced() {
        #expect(
            ReaderPageAccessibility.shouldAnnounce(
                previous: 2,
                current: 3,
                pageCount: 12
            )
        )
        #expect(
            ReaderPageAccessibility.shouldAnnounce(
                previous: 3,
                current: 2,
                pageCount: 12
            )
        )
    }

    @Test("a bounce on the same index is not announced")
    func repeatIsSilent() {
        #expect(
            ReaderPageAccessibility.shouldAnnounce(
                previous: 3,
                current: 3,
                pageCount: 12
            ) == false
        )
    }

    @Test("a single-page chapter does not announce")
    func singlePageChapterSilent() {
        #expect(
            ReaderPageAccessibility.shouldAnnounce(
                previous: 0,
                current: 1,
                pageCount: 1
            ) == false
        )
    }

    @Test("the announcement is short and self-describing")
    func announcementIsShort() {
        let text = ReaderPageAccessibility.pageTurnAnnouncement(pageIndex: 4, pageCount: 30)
        #expect(text == "Page 5 of 30")
        // A long sentence interrupts reading; keep it to the position.
        #expect(text.count < 24)
    }
}
