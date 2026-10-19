import CoreGraphics
import Foundation
import Testing
@testable import ReaderFeature

@Suite("PDF page strip geometry")
struct PDFScrubberGeometryTests {
    @Test("x maps to pages across the whole document, clamped at both ends")
    func pageFromX() {
        let width: CGFloat = 324, inset: CGFloat = 12
        #expect(PDFScrubberGeometry.pageIndex(atX: -40, width: width, inset: inset, pageCount: 585) == 0)
        #expect(PDFScrubberGeometry.pageIndex(atX: inset, width: width, inset: inset, pageCount: 585) == 0)
        #expect(PDFScrubberGeometry.pageIndex(atX: width / 2, width: width, inset: inset, pageCount: 585) == 292)
        #expect(PDFScrubberGeometry.pageIndex(atX: width - inset, width: width, inset: inset, pageCount: 585) == 584)
        #expect(PDFScrubberGeometry.pageIndex(atX: width + 40, width: width, inset: inset, pageCount: 585) == 584)
    }

    @Test("a one-page or empty document always maps to page 0")
    func degenerateDocuments() {
        #expect(PDFScrubberGeometry.pageIndex(atX: 200, width: 300, inset: 12, pageCount: 1) == 0)
        #expect(PDFScrubberGeometry.pageIndex(atX: 200, width: 300, inset: 12, pageCount: 0) == 0)
        #expect(PDFScrubberGeometry.centerX(forPage: 0, width: 300, inset: 12, pageCount: 1) == 150)
    }

    @Test("page → x → page round-trips, so the tile sits under the finger")
    func roundTrip() {
        let width: CGFloat = 360, inset: CGFloat = 12
        for page in [0, 1, 57, 292, 583, 584] {
            let x = PDFScrubberGeometry.centerX(forPage: page, width: width, inset: inset, pageCount: 585)
            let back = PDFScrubberGeometry.pageIndex(atX: x, width: width, inset: inset, pageCount: 585)
            #expect(back == page)
        }
    }

    @Test("the selected tile stays inside the capsule's rounded ends")
    func clampKeepsTileInsideCapsule() {
        let stripWidth: CGFloat = 360, stripHeight: CGFloat = 56
        let tile = CGSize(width: 37, height: 48)
        let margin: CGFloat = 2
        let first = PDFScrubberGeometry.clampedCenterX(
            12, stripWidth: stripWidth, stripHeight: stripHeight, tileSize: tile, margin: margin
        )
        let last = PDFScrubberGeometry.clampedCenterX(
            stripWidth - 12, stripWidth: stripWidth, stripHeight: stripHeight, tileSize: tile, margin: margin
        )

        // Every corner of the tile lies within the end semicircle.
        let radius = stripHeight / 2
        let left = first - tile.width / 2
        let dx = radius - left
        let dy = tile.height / 2
        #expect(left > 0)
        #expect(dx * dx + dy * dy <= radius * radius + 0.001)
        // Symmetric at the far end.
        #expect(abs((stripWidth - last) - first) < 0.001)
    }

    @Test("a tile already inside the strip is not moved")
    func clampLeavesMiddleAlone() {
        let x = PDFScrubberGeometry.clampedCenterX(
            180, stripWidth: 360, stripHeight: 56, tileSize: CGSize(width: 37, height: 48), margin: 2
        )
        #expect(x == 180)
    }

    @Test("a strip narrower than the tile centres it")
    func clampOnTinyStrip() {
        let x = PDFScrubberGeometry.clampedCenterX(
            0, stripWidth: 30, stripHeight: 56, tileSize: CGSize(width: 37, height: 48), margin: 2
        )
        #expect(x == 15)
    }

    @Test("samples include the first and last page and never exceed the page count")
    func samples() {
        let samples = PDFScrubberGeometry.sampledPageIndices(pageCount: 585, availableWidth: 336)
        #expect(samples.first == 0)
        #expect(samples.last == 584)
        #expect(samples == samples.sorted())
        #expect(PDFScrubberGeometry.sampledPageIndices(pageCount: 3, availableWidth: 336) == [0, 1, 2])
        #expect(PDFScrubberGeometry.sampledPageIndices(pageCount: 0, availableWidth: 336).isEmpty)
    }

    @Test("a short document gets a strip that hugs its pages, a long one the full width")
    func stripWidthHugsShortDocuments() {
        let inset: CGFloat = 18, minimum: CGFloat = 120
        // 10 pages: one pitch between each, plus the insets.
        #expect(PDFScrubberGeometry.stripWidth(
            pageCount: 10, availableWidth: 800, inset: inset, minimumWidth: minimum
        ) == inset * 2 + 9 * PDFScrubberGeometry.samplePitch)
        // Never narrower than the minimum, even for one page.
        #expect(PDFScrubberGeometry.stripWidth(
            pageCount: 1, availableWidth: 800, inset: inset, minimumWidth: minimum
        ) == minimum)
        // Never wider than the space available.
        #expect(PDFScrubberGeometry.stripWidth(
            pageCount: 585, availableWidth: 800, inset: inset, minimumWidth: minimum
        ) == 800)
    }

    @Test("every page of a short document is a sample, one pitch apart")
    func shortDocumentSamplesEveryPage() {
        let inset: CGFloat = 18
        let width = PDFScrubberGeometry.stripWidth(pageCount: 29, availableWidth: 1000, inset: inset, minimumWidth: 120)
        let samples = PDFScrubberGeometry.sampledPageIndices(pageCount: 29, availableWidth: width - inset * 2)
        #expect(samples == Array(0..<29))
        let a = PDFScrubberGeometry.centerX(forPage: 3, width: width, inset: inset, pageCount: 29)
        let b = PDFScrubberGeometry.centerX(forPage: 4, width: width, inset: inset, pageCount: 29)
        #expect(abs((b - a) - PDFScrubberGeometry.samplePitch) < 0.001)
    }

    @Test("nearest sample stands in for a page that is still drawing")
    func nearestSample() {
        #expect(PDFScrubberGeometry.nearestSample(to: 43, in: [0, 40, 80]) == 40)
        #expect(PDFScrubberGeometry.nearestSample(to: 75, in: [0, 40, 80]) == 80)
        #expect(PDFScrubberGeometry.nearestSample(to: 5, in: []) == nil)
    }

    @Test("prefetch goes nearest first and stays inside the document")
    func prefetchOrder() {
        #expect(PDFReaderModel.prefetchOrder(around: 10, radius: 2, pageCount: 100) == [10, 11, 9, 12, 8])
        #expect(PDFReaderModel.prefetchOrder(around: 0, radius: 2, pageCount: 100) == [0, 1, 2])
        #expect(PDFReaderModel.prefetchOrder(around: 99, radius: 2, pageCount: 100) == [99, 98, 97])
        #expect(PDFReaderModel.prefetchOrder(around: 5, radius: 0, pageCount: 100) == [5])
        #expect(PDFReaderModel.prefetchOrder(around: 5, radius: 3, pageCount: 0).isEmpty)
    }
}

@Suite("PDF contents current entry")
struct PDFContentsPositionTests {
    private func entry(_ id: String, _ page: Int, depth: Int = 0, resolves: Bool = true) -> PDFBookmark {
        PDFBookmark(id: id, title: id, pageIndex: page, depth: depth, hasDestination: resolves)
    }

    @Test("the entry starting nearest before the page is current, not only an exact match")
    func betweenEntries() {
        let outline = [entry("a", 0), entry("b", 10), entry("c", 30)]
        #expect(PDFContentsPosition.currentEntryID(in: outline, page: 15) == "b")
        #expect(PDFContentsPosition.currentEntryID(in: outline, page: 30) == "c")
        #expect(PDFContentsPosition.currentEntryID(in: outline, page: 500) == "c")
    }

    @Test("a section starting on its chapter's page wins the tie")
    func deeperEntryWinsTie() {
        let outline = [entry("ch1", 4), entry("ch1.1", 4, depth: 1), entry("ch1.2", 9, depth: 1)]
        #expect(PDFContentsPosition.currentEntryID(in: outline, page: 5) == "ch1.1")
    }

    @Test("front matter before the first entry marks nothing")
    func beforeFirstEntry() {
        #expect(PDFContentsPosition.currentEntryID(in: [entry("a", 3)], page: 1) == nil)
        #expect(PDFContentsPosition.currentEntryID(in: [], page: 1) == nil)
    }

    @Test("an entry with no destination is never current")
    func unresolvedEntries() {
        // Unresolved entries carry pageIndex 0, which would otherwise match
        // every page.
        let outline = [entry("broken", 0, resolves: false), entry("a", 2)]
        #expect(PDFContentsPosition.currentEntryID(in: outline, page: 1) == nil)
        #expect(PDFContentsPosition.currentEntryID(in: outline, page: 2) == "a")
    }
}

@Suite("PDF scrub seek coalescing")
struct PDFScrubSeekLatchTests {
    @Test("only the latest page requested within a frame is applied")
    func keepsLatest() {
        var latch = PDFScrubSeekLatch(applied: 10)
        latch.request(11)
        latch.request(12)
        latch.request(15)
        #expect(latch.take() == 15)
        #expect(latch.take() == nil)
    }

    @Test("a page already shown is not sought again")
    func skipsCurrentPage() {
        var latch = PDFScrubSeekLatch(applied: 10)
        latch.request(10)
        #expect(latch.take() == nil)
        latch.request(12)
        #expect(latch.take() == 12)
        latch.request(13)
        latch.request(12)
        #expect(latch.take() == nil)
    }

    @Test("an idle frame applies nothing")
    func idleFrame() {
        var latch = PDFScrubSeekLatch()
        #expect(latch.take() == nil)
        latch.request(0)
        #expect(latch.take() == 0)
    }
}

@Suite("PDF scrub page display")
@MainActor
struct PDFScrubStateTests {
    @Test("the badge shows the scrubbed page while scrubbing, the reader's page otherwise")
    func displayedPage() {
        let state = PDFScrubState()
        #expect(state.displayedPage(navigationPage: 7) == 7)
        state.page = 312
        #expect(state.displayedPage(navigationPage: 7) == 312)
        state.page = nil
        #expect(state.displayedPage(navigationPage: 312) == 312)
    }
}
