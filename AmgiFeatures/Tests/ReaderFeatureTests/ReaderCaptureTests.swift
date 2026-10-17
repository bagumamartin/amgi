import Foundation
import Testing
@testable import ReaderFeature

/// The pieces of capture that are pure rules: how a card's field is built
/// from text and pictures, how a capture colour is stored and read back, and
/// how a PDF capture mark names what it belongs to.
@Suite("Reader capture")
struct ReaderCaptureTests {
    @Test("a field is the side's text, then its pictures")
    func fieldWithPictures() {
        #expect(ReaderCardCapture.field("ATP <yield>", images: []) == "ATP &lt;yield&gt;")
        #expect(ReaderCardCapture.field("", images: ["a.png"]) == "<img src=\"a.png\">")
        #expect(ReaderCardCapture.field("Krebs", images: ["a.png", "b.png"])
            == "Krebs<br><img src=\"a.png\"><br><img src=\"b.png\">")
    }

    @Test("a picture's name cannot break out of its attribute")
    func fieldEscapesNames() {
        #expect(ReaderCardCapture.field("", images: ["a\"b.png"]) == "<img src=\"a&quot;b.png\">")
    }

    @Test("a card's field reads as one line of text in the dock")
    func fieldAsText() {
        #expect(ReaderCardCapture.plainText("ATP &amp; NADH<br>yield") == "ATP & NADH yield")
        #expect(ReaderCardCapture.plainText("<b>Krebs</b> <img src=\"a.png\">") == "Krebs [picture]")
    }

    @Test("every capture colour reads back from its stored hex")
    func colourRoundTrip() {
        for colour in PDFAnnotationColour.captureChoices {
            #expect(PDFAnnotationColour(captureHex: colour.hex) == colour)
            #expect(PDFAnnotationColour(captureHex: colour.hex.lowercased()) == colour)
        }
        #expect(PDFAnnotationColour(captureHex: "#123456") == nil)
        #expect(PDFAnnotationColour(captureHex: nil) == nil)
    }

    @Test("a capture mark's name carries its kind and id")
    @MainActor
    func markNames() {
        let id = UUID().uuidString
        let parsed = PDFCaptureMarks.parse("\(PDFCaptureMarks.namePrefix)cardDraft-\(id)")
        #expect(parsed?.kind == "cardDraft")
        #expect(parsed?.id == id)
        #expect(PDFCaptureMarks.parse("amgi-highlight-\(id)") == nil, "the reader's own highlights are not capture marks")
        #expect(PDFCaptureMarks.parse(nil) == nil)
    }
}
