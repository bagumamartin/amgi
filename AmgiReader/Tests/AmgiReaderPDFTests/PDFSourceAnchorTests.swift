import Foundation
import Testing
@testable import AmgiReaderPDF

/// A PDF card that points at the wrong paragraph is worse than one that admits
/// it lost its place, so the anchor's failure modes matter as much as its
/// success cases.
@Suite("PDF source anchor")
struct PDFSourceAnchorTests {
    private func anchor(
        pageIndex: Int = 340,
        pageLabel: String? = "340",
        quote: String = "the anchored sentence",
        origin: PDFSourceAnchor.Origin = .textLayer,
        confidence: Double? = nil
    ) -> PDFSourceAnchor {
        PDFSourceAnchor(
            bookID: "book-1",
            pageIndex: pageIndex,
            pageLabel: pageLabel,
            rect: PDFNormalizedRect(x: 0.1, y: 0.4, width: 0.8, height: 0.03),
            quote: quote,
            documentFingerprint: "fp-1",
            origin: origin,
            confidence: confidence
        )
    }

    // MARK: - Text layer vs OCR

    @Test("a text-layer anchor always supports a card")
    func textLayerAlwaysCardWorthy() {
        // The text layer is exact, so there is no confidence to gate on.
        #expect(anchor(origin: .textLayer).supportsCardCreation)
        #expect(anchor(origin: .textLayer, confidence: 0).supportsCardCreation)
    }

    @Test("an OCR anchor below the confidence floor does not get a card")
    func lowConfidenceOCROffersNoCard() {
        // The point of the floor: a card quoting misread text teaches the
        // learner that a wrong word is what the book said. No card is better.
        let low = anchor(origin: .ocr, confidence: 0.2)
        #expect(low.supportsCardCreation == false)
        // A missing confidence is treated as zero, not as "fine".
        #expect(anchor(origin: .ocr, confidence: nil).supportsCardCreation == false)
    }

    @Test("an OCR anchor above the floor does get a card")
    func highConfidenceOCRCardWorthy() {
        #expect(anchor(origin: .ocr, confidence: 0.93).supportsCardCreation)
        // Exactly on the floor counts, so the boundary is not a trap.
        #expect(
            anchor(origin: .ocr, confidence: PDFSourceAnchor.minimumCardConfidence)
                .supportsCardCreation
        )
    }

    @Test("confidence is only meaningful for OCR, and says so")
    func confidenceIsOCROnly() {
        // A text-layer anchor carrying a confidence would suggest the text
        // might be wrong, which is a different product decision.
        #expect(anchor(origin: .textLayer).supportsCardCreation)
    }

    // MARK: - Page label

    @Test("the book's own page label is preferred, the index is the fallback")
    func displayPageLabel() {
        #expect(anchor(pageIndex: 340, pageLabel: "xii").displayPageLabel == "xii")
        // Roman front matter and a missing label both fall back to 1-based.
        #expect(anchor(pageIndex: 339, pageLabel: nil).displayPageLabel == "340")
        #expect(anchor(pageIndex: 0, pageLabel: nil).displayPageLabel == "1")
    }

    // MARK: - Rect normalisation

    @Test("a PDF rect survives the trip to normalised space and back")
    func rectRoundTrips() {
        let pageWidth = 612.0   // US Letter
        let pageHeight = 792.0
        // A rect in PDF user space, origin bottom-left.
        let original = PDFRect(x: 61.2, y: 396, width: 306, height: 24)
        let normalized = PDFNormalizedRect(
            pdfRect: original,
            pageWidth: pageWidth,
            pageHeight: pageHeight
        )
        let back = normalized.pdfRect(pageWidth: pageWidth, pageHeight: pageHeight)
        #expect(abs(back.x - original.x) < 0.001)
        #expect(abs(back.y - original.y) < 0.001)
        #expect(abs(back.width - original.width) < 0.001)
        #expect(abs(back.height - original.height) < 0.001)
    }

    @Test("normalised space is top-left, matching the renderer's own axes")
    func normalizedSpaceIsTopLeft() {
        // PDF user space has y increasing upward. Every renderer in the app
        // thinks top-down, so the conversion has to flip — otherwise a crop
        // lands in the wrong place and nothing would look obviously wrong.
        let pageWidth = 100.0
        let pageHeight = 200.0
        // A strip at the very top of the page in PDF space: y near the top.
        let topStrip = PDFNormalizedRect(
            pdfRect: PDFRect(x: 0, y: 180, width: 100, height: 20),
            pageWidth: pageWidth,
            pageHeight: pageHeight
        )
        #expect(abs(topStrip.y) < 0.001, "top of the page must normalise to y = 0")

        // And the bottom of the page must normalise to the bottom.
        let bottomStrip = PDFNormalizedRect(
            pdfRect: PDFRect(x: 0, y: 0, width: 100, height: 20),
            pageWidth: pageWidth,
            pageHeight: pageHeight
        )
        #expect(abs(bottomStrip.y + bottomStrip.height - 1) < 0.001)
    }

    @Test("a selection overhanging the page box is clamped, not off-page")
    func overhangIsClamped() {
        // A whole-paragraph selection frequently overhangs the crop box. Left
        // unclamped it would produce a coordinate outside 0...1 and the crop
        // code would sample off-page — a blank image with no error.
        let clamped = PDFNormalizedRect(
            pdfRect: PDFRect(x: -20, y: -10, width: 200, height: 400),
            pageWidth: 100,
            pageHeight: 200
        )
        #expect(clamped.isValid)
        #expect((0...1).contains(clamped.x))
        #expect((0...1).contains(clamped.y))
        #expect((0...1).contains(clamped.x + clamped.width))
        #expect((0...1).contains(clamped.y + clamped.height))
    }

    @Test("a degenerate page size does not divide by zero")
    func degeneratePageSize() {
        // A malformed document can declare a zero-sized page. The conversion
        // must not produce NaN, which would propagate into a crop request.
        let rect = PDFNormalizedRect(
            pdfRect: PDFRect(x: 0, y: 0, width: 10, height: 10),
            pageWidth: 0,
            pageHeight: 0
        )
        #expect(rect.isEmpty)
        #expect(rect.x.isFinite && rect.y.isFinite)
    }

    @Test("a zero-area rect is treated as absent")
    func zeroAreaIsInvalid() {
        // A zero-area region cannot be cropped or hit-tested, so treating it
        // as present would pass it downstream to fail obscurely.
        #expect(PDFNormalizedRect(x: 0.5, y: 0.5, width: 0, height: 0.1).isEmpty)
        #expect(PDFNormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1).isValid)
    }

    // MARK: - Quote normalisation

    @Test("quote comparison ignores reflowed line breaks")
    func quoteNormalisation() {
        // Verification compares a stored quote against freshly-read page text.
        // If that text rewrapped, an exact comparison would fail and the
        // annotation would be reported as lost on a document that never moved.
        let a = PDFSourceAnchor.normalize("the quick\n   brown\tfox")
        let b = PDFSourceAnchor.normalize("the quick brown fox")
        #expect(a == b)
        #expect(PDFSourceAnchor.normalize("  spaced  ") == "spaced")
    }

    @Test("normalisation preserves case and punctuation")
    func normalisationPreservesMeaning() {
        #expect(PDFSourceAnchor.normalize("Hello, World.") == "Hello, World.")
    }

    // MARK: - Codable

    @Test("an anchor round-trips through JSON unchanged")
    func codableRoundTrip() throws {
        let original = PDFSourceAnchor(
            bookID: "book-1",
            pageIndex: 12,
            pageLabel: "xiii",
            rect: PDFNormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05),
            quote: "a quoted passage",
            contextBefore: "before",
            contextAfter: "after",
            documentFingerprint: "fp-abcdef",
            origin: .ocr,
            confidence: 0.81,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PDFSourceAnchor.self, from: data)
        #expect(decoded == original)
    }

    @Test("an anchor is versioned so a future shape can be told apart")
    func anchorIsVersioned() {
        #expect(anchor().version == PDFSourceAnchor.currentVersion)
    }
}

@Suite("PDF document fingerprint")
struct PDFDocumentFingerprintTests {
    private func samples(_ count: Int) -> [(pageIndex: Int, width: Double, height: Double, textPrefix: String)] {
        (0..<count).map {
            (pageIndex: $0, width: 612, height: 792, textPrefix: "page \($0) text")
        }
    }

    @Test("the same document always fingerprints the same")
    func stableForSameDocument() {
        let a = PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: samples(9))
        let b = PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: samples(9))
        #expect(a == b)
    }

    @Test("sample order does not change the fingerprint")
    func orderIndependent() {
        // A renderer walking pages in a different order must not produce a
        // different answer, or every device would disagree about whether the
        // document changed.
        let ordered = samples(9)
        let shuffled = ordered.reversed()
        #expect(
            PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: Array(ordered))
                == PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: Array(shuffled))
        )
    }

    @Test("a repaginated document is detected")
    func detectsRepagination() {
        // Re-running "print to PDF" shifts text between pages. The text sampled
        // from a given page index therefore changes, and the fingerprint must
        // notice — this is the case that makes every page-anchored annotation
        // suspect.
        let before = PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: samples(9))
        var shifted = samples(9)
        shifted[4] = (pageIndex: 4, width: 612, height: 792, textPrefix: "different text here")
        let after = PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: shifted)
        #expect(before != after)
    }

    @Test("a page-count change is detected")
    func detectsPageCountChange() {
        let a = PDFDocumentFingerprint.fingerprint(pageCount: 300, samples: samples(9))
        let b = PDFDocumentFingerprint.fingerprint(pageCount: 301, samples: samples(9))
        #expect(a != b)
    }

    @Test("a geometry change is detected")
    func detectsGeometryChange() {
        // A different page size — A4 re-exported from a Letter original —
        // invalidates normalised coordinates even when the text is identical.
        let letter = PDFDocumentFingerprint.fingerprint(pageCount: 10, samples: samples(3))
        let a4 = PDFDocumentFingerprint.fingerprint(
            pageCount: 10,
            samples: (0..<3).map { (pageIndex: $0, width: 595, height: 842, textPrefix: "page \($0) text") }
        )
        #expect(letter != a4)
    }

    @Test("sampling is cheap but includes both ends")
    func samplingIsBounded() {
        // Hashing 400 pages to answer a question that rarely changes is a bad
        // trade; sampling a handful is not. Both ends matter because that is
        // where a repagination shows first.
        let indices = PDFDocumentFingerprint.sampleIndices(pageCount: 400)
        #expect(indices.count == PDFDocumentFingerprint.sampleCount)
        #expect(indices.first == 0)
        #expect(indices.last == 399)
        #expect(indices == indices.sorted(), "samples must ascend")
        #expect(Set(indices).count == indices.count, "no page sampled twice")
    }

    @Test("a short document is sampled in full")
    func shortDocumentsSampledInFull() {
        let indices = PDFDocumentFingerprint.sampleIndices(pageCount: 4)
        #expect(indices == [0, 1, 2, 3])
        #expect(PDFDocumentFingerprint.sampleIndices(pageCount: 0).isEmpty)
        #expect(PDFDocumentFingerprint.sampleIndices(pageCount: 1) == [0])
    }

    @Test("sub-point geometry jitter is not treated as a change")
    func ignoresFloatNoise() {
        // Renderers report dimensions as floats, and the same document can come
        // back differing in the last decimal place. Treating that as a change
        // would invalidate every annotation on every open.
        let exact = PDFDocumentFingerprint.fingerprint(
            pageCount: 5,
            samples: (0..<5).map { ($0, 612.0, 792.0, "text") }
        )
        let noisy = PDFDocumentFingerprint.fingerprint(
            pageCount: 5,
            samples: (0..<5).map { ($0, 612.0001, 792.0001, "text") }
        )
        #expect(exact == noisy)
    }

    @Test("the short form is usable in logs")
    func shortForm() {
        let full = PDFDocumentFingerprint.fingerprint(pageCount: 10, samples: samples(3))
        #expect(PDFDocumentFingerprint.short(full).count == 12)
        #expect(full.hasPrefix(PDFDocumentFingerprint.short(full)))
    }
}
