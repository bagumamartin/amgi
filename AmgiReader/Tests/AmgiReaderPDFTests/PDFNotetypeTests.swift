import Foundation
import Testing
@testable import AmgiReaderPDF

/// The dedicated PDF notetype is a piece of schema the user owns, so its shape
/// is worth pinning: field names are persisted in their collection and renaming
/// one would orphan every existing card.
@Suite("PDF notetype")
struct PDFNotetypeTests {
    private func anchor(
        pageIndex: Int = 339,
        pageLabel: String? = "340",
        rect: PDFNormalizedRect? = PDFNormalizedRect(
            x: 0.1, y: 0.4, width: 0.8, height: 0.03
        ),
        quote: String = "a sentence from the page",
        origin: PDFSourceAnchor.Origin = .textLayer,
        confidence: Double? = nil
    ) -> PDFSourceAnchor {
        PDFSourceAnchor(
            bookID: "book-1",
            pageIndex: pageIndex,
            pageLabel: pageLabel,
            rect: rect,
            quote: quote,
            documentFingerprint: "abcdef0123456789",
            origin: origin,
            confidence: confidence
        )
    }

    private func appending(
        _ quote: String,
        side: PDFCardSide = .front,
        pageIndex: Int = 339,
        pageLabel: String? = "340",
        region: String? = nil,
        origin: PDFSourceAnchor.Origin = .textLayer,
        confidence: Double? = nil
    ) -> PDFCardAppending {
        PDFCardAppending(
            side: side,
            provenance: .selection(
                PDFCardSelection(
                    quote: quote,
                    anchor: anchor(
                        pageIndex: pageIndex,
                        pageLabel: pageLabel,
                        quote: quote,
                        origin: origin,
                        confidence: confidence
                    ),
                    regionMediaName: region,
                    pageLabel: pageLabel ?? String(pageIndex + 1)
                )
            )
        )
    }

    @Test("the field list is the one that goes into the collection")
    func fieldContract() {
        // These names are written into the user's notetype. Changing one is a
        // breaking change that silently breaks every card made so far.
        #expect(PDFNotetype.fieldNames == ["Front", "Back", "Page", "Region", "Source"])
        #expect(PDFNotetype.name == "IJUKA PDF")
        // Exactly one prompt, or Anki will not generate cards from the template.
        #expect(PDFNotetype.Field.allCases.filter(\.isPrompt).count == 1)
        #expect(PDFNotetype.Field.front.isPrompt)
    }

    @Test("a card fills Front, Back, Page and Source")
    func requiredFieldsPresent() {
        let payload = PDFCardPayload(
            front: [appending("atherosclerosis")],
            back: [
                appending(
                    "The occlusion of a coronary artery by a thrombus.",
                    side: .back
                )
            ]
        )
        let values = payload.fieldValueDictionary()
        #expect(values["Front"] == "atherosclerosis")
        #expect(values["Back"] == "The occlusion of a coronary artery by a thrombus.")
        #expect(values["Page"] == "340")
        #expect(values["Source"] != nil)
    }

    @Test("an absent region is omitted rather than left blank")
    func regionOmittedWhenAbsent() {
        // An empty column is visible in Anki's browser and in the editor, so a
        // text-only card should not carry a blank Region field.
        let withoutRegion = PDFCardPayload(
            front: [appending("t")],
            back: []
        )
        #expect(withoutRegion.fieldValueDictionary()["Region"] == nil)

        let withRegion = PDFCardPayload(
            front: [appending("t", region: "amgi-pdf-region_abcdef012345_1.png")],
            back: []
        )
        #expect(
            withRegion.fieldValueDictionary()["Region"]
                == "amgi-pdf-region_abcdef012345_1.png"
        )
    }

    @Test("several regions are space-separated so the template can render them all")
    func severalRegionsAreSpaceSeparated() {
        // `{{Media: field}}` parses a whitespace-separated list, so a comma
        // here would produce one broken image reference instead of two good ones.
        let payload = PDFCardPayload(
            front: [
                appending("a", region: "one.png"),
                appending("b", region: "two.png"),
            ],
            back: []
        )
        #expect(payload.fieldValueDictionary()["Region"] == "one.png two.png")
    }

    @Test("appendings on a side are joined with a newline, not concatenated")
    func joinsWithNewline() {
        // Concatenation produces "the quickbrown fox" from "the quick" and
        // "brown fox", and the missing space is invisible until the card is in
        // review.
        let payload = PDFCardPayload(
            front: [appending("the quick"), appending("brown fox")],
            back: []
        )
        #expect(payload.fieldValueDictionary()["Front"] == "the quick\nbrown fox")
    }

    @Test("Page lists every page the card draws on")
    func pageListsEveryPage() {
        // Not the first. A card assembled from page 12 and page 340 that cites
        // "page 12" is not a small inaccuracy — it points the reader at the
        // wrong place, which is the only thing the page number is for.
        let payload = PDFCardPayload(
            front: [appending("a", pageIndex: 11, pageLabel: "12")],
            back: [appending("b", side: .back, pageIndex: 339, pageLabel: "340")]
        )
        #expect(payload.fieldValueDictionary()["Page"] == "12, 340")
    }

    @Test("a page quoted three times is listed once")
    func pageDeduplicates() {
        let payload = PDFCardPayload(
            front: [
                appending("a", pageIndex: 11, pageLabel: "12"),
                appending("b", pageIndex: 11, pageLabel: "12"),
                appending("c", pageIndex: 11, pageLabel: "12"),
            ],
            back: []
        )
        #expect(payload.fieldValueDictionary()["Page"] == "12")
    }

    @Test("Source names one primary anchor and keeps the rest")
    func sourceKeepsEveryAnchor() throws {
        // A card with two anchors and one field value loses the second source
        // entirely, so `primary` is explicit and `all` is not truncated.
        let first = appending("a", pageIndex: 11, pageLabel: "12")
        let second = appending("b", side: .back, pageIndex: 339, pageLabel: "340")
        let payload = PDFCardPayload(front: [first], back: [second])
        let encoded = try #require(payload.fieldValueDictionary()["Source"])
        let decoded = try JSONDecoder().decode(
            PDFCardSource.self,
            from: Data(encoded.utf8)
        )
        // The first appending, not the first page and not the longest quote.
        #expect(decoded.primary.pageIndex == 11)
        #expect(decoded.all.count == 2)
        #expect(decoded.all.map(\.pageIndex) == [11, 339])
    }

    @Test("a Source that names only a primary still decodes")
    func sourceToleratesAMissingAll() throws {
        // A half-written park must not fail in a way that loses the primary too.
        let encoded = try JSONEncoder().encode(
            PDFCardSource(primary: anchor(), all: [anchor()])
        )
        var object = try JSONSerialization.jsonObject(
            with: encoded
        ) as! [String: Any]
        object.removeValue(forKey: "all")
        let decoded = try JSONDecoder().decode(
            PDFCardSource.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.all.count == 1)
        #expect(decoded.primary.pageIndex == 339)
    }

    @Test("the positional projection keeps every field's slot")
    func orderedValuesArePositional() {
        // `NewNoteTemplate.fields` is indexed by ordinal, not by name. A short
        // array does not skip a field, it shifts every field after the gap into
        // the wrong column — which is how a page number ends up in Source.
        let payload = PDFCardPayload(front: [appending("t")], back: [])
        let fields = payload.orderedFieldValues(against: PDFNotetype.fieldNames)
        #expect(fields.count == PDFNotetype.fieldNames.count)
        #expect(fields[0] == "t")
        // No back, no region: empty, but present, because the array is
        // positional. This is the one place a blank is correct.
        #expect(fields[1] == "")
        #expect(fields[2] == "340")
        #expect(fields[3] == "")
    }

    @Test("a card with no front cannot become a note")
    func emptyFrontRejected() {
        // A note with no prompt generates no card in Anki, so writing one
        // silently loses the appendings.
        #expect(PDFCardPayload(front: [], back: []).isCardWorthy == false)
        #expect(
            PDFCardPayload(front: [], back: [appending("b", side: .back)])
                .isCardWorthy == false
        )
        #expect(PDFCardPayload(front: [appending("t")], back: []).isCardWorthy)
    }

    @Test("a card with only a back is still worth keeping")
    func oneSidedCardIsWorthy() {
        // Anki renders a one-sided card fine, and refusing would throw away
        // appendings the user spent the session collecting.
        #expect(
            PDFCardPayload(
                front: [],
                back: [appending("an example sentence", side: .back)]
            ).isCardWorthy == false
        )
    }

    @Test("a low-confidence OCR card is flagged as uncertain")
    func lowConfidenceCardFlagged() {
        // The region image is still usable, so the card is worth showing — but
        // the recognised text must not be presented as what the page said.
        let uncertain = PDFCardPayload(
            front: [appending("infarctlon", origin: .ocr, confidence: 0.3)],
            back: []
        )
        #expect(uncertain.carriesUncertainTextWarning)

        let confident = PDFCardPayload(
            front: [appending("infarction", origin: .ocr, confidence: 0.94)],
            back: []
        )
        #expect(confident.carriesUncertainTextWarning == false)
    }

    @Test("text-layer text is never flagged as uncertain")
    func textLayerNotFlagged() {
        let payload = PDFCardPayload(front: [appending("t")], back: [])
        #expect(payload.carriesUncertainTextWarning == false)
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

    @Test("the card template renders the region image on the question side")
    func templateRendersRegion() {
        // A card built from a figure is asking "what is this?". Showing the
        // figure only on the answer side would leave the prompt reading "which
        // of these does this refer to?" with nothing to refer to.
        #expect(PDFNotetype.questionFormat.contains("{{Front}}"))
        #expect(PDFNotetype.questionFormat.contains("{{Media: Region}}"))
        #expect(PDFNotetype.answerFormat.contains("{{Back}}"))
        #expect(PDFNotetype.answerFormat.contains("{{Page}}"))
        // `{{#Field}}…{{/Field}}` is Anki's non-empty conditional: an empty
        // Region renders nothing at all rather than an empty div.
        #expect(PDFNotetype.questionFormat.contains("{{#Region}}"))
    }
}
