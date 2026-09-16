import Foundation
import Testing
@testable import BrowseFeature

@Suite("Note field HTML codec")
struct NoteFieldHTMLTests {
    @Test func emptyStaysEmpty() {
        #expect(NoteFieldHTML.roundTrip("") == "")
        #expect(NoteFieldHTML.attributedString(from: "").string == "")
    }

    @Test func plainTextRoundTrips() {
        #expect(NoteFieldHTML.roundTrip("hello") == "hello")
    }

    @Test func newlinesBecomeBrAndBack() {
        let html = "line one<br>line two"
        let attributed = NoteFieldHTML.attributedString(from: html)
        #expect(attributed.string == "line one\nline two")
        #expect(NoteFieldHTML.encode(attributed) == html)
    }

    @Test func brVariantsBecomeNewlines() {
        #expect(NoteFieldHTML.attributedString(from: "a<br/>b").string == "a\nb")
        #expect(NoteFieldHTML.attributedString(from: "a<br />b").string == "a\nb")
        #expect(NoteFieldHTML.attributedString(from: "a<BR>b").string == "a\nb")
    }

    @Test func divAndParagraphClosesBecomeNewlines() {
        let html = "<div>first</div><div>second</div>"
        #expect(NoteFieldHTML.attributedString(from: html).string == "first\nsecond")
        #expect(NoteFieldHTML.roundTrip(html) == "first<br>second")
        #expect(NoteFieldHTML.attributedString(from: "<p>a</p><p>b</p>").string == "a\nb")
    }

    @Test func internalBlankLineSurvives() {
        let attributed = NoteFieldHTML.attributedString(from: "a<br><br>b")
        #expect(attributed.string == "a\n\nb")
        #expect(NoteFieldHTML.encode(attributed) == "a<br><br>b")
    }

    @Test func boldItalicUnderlineStrikeRoundTrip() {
        let html = "<b>bold</b> <i>italic</i> <u>under</u> <s>strike</s>"
        let attributed = NoteFieldHTML.attributedString(from: html)
        #expect(attributed.string == "bold italic under strike")

        let full = NSRange(location: 0, length: attributed.length)
        var sawBold = false
        var sawItalic = false
        var sawUnderline = false
        var sawStrike = false
        attributed.enumerateAttributes(in: full, options: []) { attributes, _, _ in
            let style = NoteFieldHTML.style(from: attributes)
            if style.bold { sawBold = true }
            if style.italic { sawItalic = true }
            if style.underline { sawUnderline = true }
            if style.strike { sawStrike = true }
        }
        #expect(sawBold)
        #expect(sawItalic)
        #expect(sawUnderline)
        #expect(sawStrike)
        #expect(NoteFieldHTML.encode(attributed) == html)
    }

    @Test func stackedInlineTagsRoundTripAsStyledRuns() {
        let html = "<b><i>both</i></b>"
        let attributed = NoteFieldHTML.attributedString(from: html)
        #expect(attributed.string == "both")
        let style = NoteFieldHTML.style(from: attributed.attributes(at: 0, effectiveRange: nil))
        #expect(style.bold)
        #expect(style.italic)
        let encoded = NoteFieldHTML.encode(attributed)
        let again = NoteFieldHTML.attributedString(from: encoded)
        let againStyle = NoteFieldHTML.style(from: again.attributes(at: 0, effectiveRange: nil))
        #expect(againStyle.bold)
        #expect(againStyle.italic)
        #expect(again.string == "both")
    }

    @Test func strongAndEmMapToBoldItalic() {
        let attributed = NoteFieldHTML.attributedString(from: "<strong>a</strong><em>b</em>")
        #expect(attributed.string == "ab")
        #expect(NoteFieldHTML.style(from: attributed.attributes(at: 0, effectiveRange: nil)).bold)
        #expect(NoteFieldHTML.style(from: attributed.attributes(at: 1, effectiveRange: nil)).italic)
    }

    @Test func unknownTagsKeepInnerTextAndBlockBreaks() {
        let html = #"<span class="foo">keep</span><div>next</div>"#
        #expect(NoteFieldHTML.attributedString(from: html).string == "keep\nnext")
    }

    @Test func entitiesDecodeOnLoadAndEscapeOnSave() {
        let attributed = NoteFieldHTML.attributedString(from: "A &amp; B &lt;C&gt;")
        #expect(attributed.string == "A & B <C>")
        #expect(NoteFieldHTML.encode(attributed) == "A &amp; B &lt;C&gt;")
    }

    @Test func mathjaxNormalizesToDelimitedTex() {
        let inline = #"<anki-mathjax>x^2</anki-mathjax>"#
        #expect(NoteFieldHTML.normalizeMathJax(inline) == #"\(x^2\)"#)
        let block = #"<anki-mathjax block="true">x^2</anki-mathjax>"#
        #expect(NoteFieldHTML.normalizeMathJax(block) == #"\[x^2\]"#)
        #expect(NoteFieldHTML.attributedString(from: inline).string == #"\(x^2\)"#)
    }

    @Test func typedNewlinesEncodeAsBr() {
        let attributed = NSAttributedString(
            string: "front\nback",
            attributes: NoteFieldHTML.attributes(for: .init(), font: NoteFieldHTML.defaultFont())
        )
        #expect(NoteFieldHTML.encode(attributed) == "front<br>back")
    }

    @Test func listsRoundTripAsUlLi() {
        let html = "<ul><li>alpha</li><li>beta</li></ul>"
        let attributed = NoteFieldHTML.attributedString(from: html)
        #expect(attributed.string == "alpha\nbeta")
        #expect(NoteFieldHTML.listKind(in: attributed, at: 0) == .bullet)
        let encoded = NoteFieldHTML.encode(attributed)
        #expect(encoded.contains("<ul"))
        #expect(encoded.contains("<li>alpha</li>"))
        #expect(encoded.contains("<li>beta</li>"))
    }

    @Test func clozeOrdinalPicksNextNumber() {
        #expect(NoteFieldHTML.nextClozeOrdinal(in: ["{{c1::one}} and {{c3::three}}"]) == 4)
        let wrapped = NoteFieldHTML.wrapCloze("hello world", selected: NSRange(location: 6, length: 5), ordinal: 2)
        #expect(wrapped.text == "hello {{c2::world}}")
    }

    @Test func emptyParagraphStartsAList() {
        let font = NoteFieldHTML.defaultFont()
        let attributed = NSMutableAttributedString()
        _ = NoteFieldHTML.toggleListKind(
            on: attributed,
            range: NSRange(location: 0, length: 0),
            kind: .bullet,
            font: font
        )
        #expect(NoteFieldHTML.listKind(in: attributed, at: 0) == .bullet)
        let encoded = NoteFieldHTML.encode(attributed)
        #expect(encoded.contains("<ul"))
        #expect(encoded.contains("list-style-type: disc"))
    }

    @Test func letterAndRomanListsRoundTrip() {
        let html = #"<ol style="list-style-type: lower-alpha; text-align: left"><li>alpha</li></ol>"#
        let attributed = NoteFieldHTML.attributedString(from: html)
        #expect(NoteFieldHTML.listKind(in: attributed, at: 0) == .lowerAlpha)
        #expect(NoteFieldHTML.encode(attributed).contains("lower-alpha"))
    }

    @Test func explicitAlignmentRoundTrips() {
        let html = #"<div style="text-align: left">hello</div>"#
        let attributed = NoteFieldHTML.attributedString(from: html)
        #expect(NoteFieldHTML.blockStyle(in: attributed, at: 0).alignment == .left)
        #expect(NoteFieldHTML.encode(attributed).contains("text-align: left"))
    }

    @Test func indentIsStoredOnParagraph() {
        let font = NoteFieldHTML.defaultFont()
        let attributed = NSMutableAttributedString(
            string: "hello",
            attributes: NoteFieldHTML.attributes(for: .init(), font: font)
        )
        NoteFieldHTML.changeIndent(on: attributed, range: NSRange(location: 0, length: 0), delta: 1, font: font)
        #expect(NoteFieldHTML.blockStyle(in: attributed, at: 0).indent == 1)
        #expect(NoteFieldHTML.encode(attributed).contains("margin-left"))
    }

    @Test func imageTagRoundTrips() {
        let html = #"<img src="paste-cat.jpg">"#
        #expect(NoteFieldHTML.roundTrip(html) == html)
    }

    @Test func imageAttachmentEncodesFilenameWithoutCustomAttribute() {
        let font = NoteFieldHTML.defaultFont()
        let attributed = NoteFieldHTML.imagePlaceholder(filename: "paste-cat.jpg", font: font)
        let stripped = NSMutableAttributedString(attributedString: attributed)
        stripped.enumerateAttributes(in: NSRange(location: 0, length: stripped.length)) { attributes, range, _ in
            var next = attributes
            next.removeValue(forKey: NoteFieldHTML.imageFilenameKey)
            stripped.setAttributes(next, range: range)
        }
        #expect(NoteFieldHTML.encode(stripped) == #"<img src="paste-cat.jpg">"#)
    }
}
