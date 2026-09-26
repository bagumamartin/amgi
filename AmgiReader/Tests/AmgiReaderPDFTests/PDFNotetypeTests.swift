import Foundation
import Testing
@testable import AmgiReaderPDF

/// The dedicated PDF notetype is a piece of schema the user owns, so its shape
/// is worth pinning: field names are persisted in their collection and renaming
/// one would orphan every existing card.
@Suite("PDF notetype")
struct PDFNotetypeTests {
    private func anchor(
        origin: PDFSourceAnchor.Origin = .textLayer,
        confidence: Double? = nil
    ) -> PDFSourceAnchor {
        PDFSourceAnchor(
            bookID: "book-1",
            pageIndex: 339,
            pageLabel: "340",
            rect: PDFNormalizedRect(x: 0.1, y: 0.4, width: 0.8, height: 0.03),
            quote: "a sentence from the page",
            documentFingerprint: "abcdef0123456789",
            origin: origin,
            confidence: confidence
        )
    }

    @Test("the field list is the one that goes into the collection")
    func fieldContract() {
        // These names are written into the user's notetype. Changing one is a
        // breaking change that silently breaks every card made so far.
        #expect(PDFNotetype.fieldNames == ["Term", "Sentence", "Page", "Region", "Source"])
        #expect(PDFNotetype.name == "IJUKA PDF")
        // Exactly one prompt, or Anki will not generate cards from the template.
        #expect(PDFNotetype.Field.allCases.filter(\.isPrompt).count == 1)
        #expect(PDFNotetype.Field.term.isPrompt)
    }

    @Test("a card fills Term, Sentence, Page and Source")
    func requiredFieldsPresent() throws {
        let payload = PDFCardPayload(
            term: "atherosclerosis",
            sentence: "The occlusion of a coronary artery by a thrombus.",
            pageLabel: "340",
            anchor: anchor()
        )
        let values = payload.fieldValues()
        let names = values.map(\.field)
        #expect(names == ["Term", "Sentence", "Page", "Source"])
        #expect(values.first { $0.field == "Term" }?.value == "atherosclerosis")
        #expect(values.first { $0.field == "Page" }?.value == "340")
    }

    @Test("an absent region is omitted rather than left blank")
    func regionOmittedWhenAbsent() {
        // An empty column is visible in Anki's browser and in the editor, so a
        // text-only card should not carry a blank Region field.
        let withoutRegion = PDFCardPayload(
            term: "t", sentence: "s", pageLabel: "1", anchor: anchor()
        )
        #expect(withoutRegion.fieldValues().map(\.field).contains("Region") == false)

        let withRegion = PDFCardPayload(
            term: "t", sentence: "s", pageLabel: "1",
            anchor: anchor(),
            regionMediaName: "amgi-pdf-region_abcdef012345_1.png"
        )
        #expect(withRegion.fieldValues().map(\.field).contains("Region"))
    }

    @Test("the Source field carries a decodable anchor")
    func sourceFieldCarriesAnchor() throws {
        let original = anchor()
        let payload = PDFCardPayload(
            term: "t", sentence: "s", pageLabel: "340", anchor: original
        )
        let encoded = try #require(
            payload.fieldValues().first { $0.field == "Source" }?.value
        )
        let decoded = try JSONDecoder().decode(
            PDFSourceAnchor.self,
            from: Data(encoded.utf8)
        )
        #expect(decoded == original)
    }

    @Test("a card with no term is not card-worthy")
    func emptyTermRejected() {
        let blank = PDFCardPayload(term: "   ", sentence: "s", pageLabel: "1", anchor: anchor())
        #expect(blank.isCardWorthy == false)
        let real = PDFCardPayload(term: "term", sentence: "s", pageLabel: "1", anchor: anchor())
        #expect(real.isCardWorthy)
    }

    @Test("a low-confidence OCR card is not offered, and says why")
    func lowConfidenceCardRejected() {
        // The region image is still usable, so the card is worth showing — but
        // the recognised text must not be presented as what the page said.
        let uncertain = PDFCardPayload(
            term: "infarctlon",
            sentence: "recognised text",
            pageLabel: "340",
            anchor: anchor(origin: .ocr, confidence: 0.3),
            isRecognisedText: true,
            confidence: 0.3
        )
        #expect(uncertain.isCardWorthy == false)
        #expect(uncertain.carriesUncertainTextWarning)

        let confident = PDFCardPayload(
            term: "infarction",
            sentence: "recognised text",
            pageLabel: "340",
            anchor: anchor(origin: .ocr, confidence: 0.94),
            isRecognisedText: true,
            confidence: 0.94
        )
        #expect(confident.isCardWorthy)
        #expect(confident.carriesUncertainTextWarning == false)
    }

    @Test("text-layer text is never flagged as uncertain")
    func textLayerNotFlagged() {
        let payload = PDFCardPayload(
            term: "t", sentence: "s", pageLabel: "1", anchor: anchor()
        )
        #expect(payload.carriesUncertainTextWarning == false)
        #expect(payload.isRecognisedText == false)
    }

    @Test("region media names are namespaced and content-addressed")
    func regionMediaNaming() {
        // Prefixed so the media folder can be cleaned or searched, and
        // content-addressed so re-capturing the same region reuses the file
        // rather than accumulating near-duplicates.
        let name = PDFNotetype.regionMediaName(
            documentFingerprint: "abcdef0123456789abcdef",
            anchorID: "1E071540"
        )
        #expect(name.hasPrefix("amgi-pdf-region"))
        #expect(name.hasSuffix(".png"))
        #expect(name.contains("abcdef012345"))
        #expect(PDFNotetype.regionMediaPrefix == "amgi-pdf-region")

        // Two documents must not collide.
        let other = PDFNotetype.regionMediaName(
            documentFingerprint: "ffffffffffffffffffff",
            anchorID: "1E071540"
        )
        #expect(other != name)
    }
}

@Suite("PDF outline")
struct PDFOutlineTests {
    @Test("outline identity is structural, not positional")
    func outlineIDIsStructural() {
        // Deliberately not derived from the destination: a document that keeps
        // its structure but repaginates should keep its chapter IDs, or every
        // saved reading position in it would be invalidated.
        #expect(PDFOutlineEntry.outlineID(path: [0]) == "outline:0")
        #expect(PDFOutlineEntry.outlineID(path: [1, 2]) == "outline:1.2")
        #expect(PDFOutlineEntry.outlineID(path: [0]) != PDFOutlineEntry.outlineID(path: [1]))
    }

    @Test("a document's own page labels are preferred, with a fallback")
    func pageLabelFallback() {
        let withLabels = PDFDocumentDescriptor(
            bookID: "b", title: "t", pageCount: 3,
            pageLabels: ["i", "ii", nil],
            hasTextLayer: true,
            documentFingerprint: "fp"
        )
        #expect(withLabels.label(forPageIndex: 0) == "i")
        #expect(withLabels.label(forPageIndex: 1) == "ii")
        // A nil label in the middle falls back to the 1-based index.
        #expect(withLabels.label(forPageIndex: 2) == "3")

        let withoutLabels = PDFDocumentDescriptor(
            bookID: "b", title: "t", pageCount: 3,
            hasTextLayer: true,
            documentFingerprint: "fp"
        )
        #expect(withoutLabels.label(forPageIndex: 0) == "1")
        // And an out-of-range index does not trap.
        #expect(withoutLabels.label(forPageIndex: 99) == "100")
    }
}
