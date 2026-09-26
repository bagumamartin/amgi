import AmgiReaderPDF
import CoreGraphics
import Foundation
import Testing
@testable import ReaderFeature

/// The reader's navigation model.
///
/// The behaviour here is what makes the reader feel like Preview rather than
/// like a scroll view with page numbers, and most of it is about *not* doing
/// something: not jumping on a programmatic move, not leaving half a spread
/// behind, not recording the act of opening a book as reading progress.
@Suite("PDF reader navigation")
@MainActor
struct PDFReaderNavigationTests {
    @Test("a page change is clamped to the document")
    func clampsToDocument() {
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 99, label: "99", count: 10, userInitiated: true)
        #expect(navigation.pageIndex == 9)
        navigation.move(toPage: -5, label: "1", count: 10, userInitiated: true)
        #expect(navigation.pageIndex == 0)
    }

    @Test("a document with no pages does not go negative")
    func handlesAnEmptyDocument() {
        // A zero-page document reaches the reader when a file is truncated or a
        // page tree is unreadable, and `-1` as a page index propagates into
        // every "page N of M" string the UI shows.
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 3, label: "4", count: 0, userInitiated: true)
        #expect(navigation.pageIndex == 0)
    }

    @Test("turning advances one page at a time in single-page mode")
    func singlePageTurn() {
        let navigation = PDFReaderNavigation()
        navigation.isTwoUp = false
        #expect(navigation.turn(by: 1, from: 4) == 5)
        #expect(navigation.turn(by: -1, from: 4) == 3)
    }

    @Test("turning never goes before the first page")
    func turnStopsAtTheStart() {
        let navigation = PDFReaderNavigation()
        #expect(navigation.turn(by: -1, from: 0) == 0)
    }

    @Test("two-up advances by a whole spread")
    func twoUpTurnMovesTwoPages() {
        // Advancing by one in two-up leaves half the previous spread beside the
        // new one, which is the single most obvious sign that a "two page"
        // setting is not actually working.
        let navigation = PDFReaderNavigation()
        navigation.isTwoUp = true
        #expect(navigation.turn(by: 1, from: 0) == 2)
        #expect(navigation.turn(by: 1, from: 2) == 4)
    }

    @Test("a two-up spread always starts on an even page")
    func twoUpAlignsToSpreadStart() {
        // A spread is pages 0-1, 2-3 and so on. Landing on an odd page would
        // leave a lone page with nothing beside it.
        #expect(PDFReaderNavigation.alignToSpreadStart(0) == 0)
        #expect(PDFReaderNavigation.alignToSpreadStart(1) == 0)
        #expect(PDFReaderNavigation.alignToSpreadStart(2) == 2)
        #expect(PDFReaderNavigation.alignToSpreadStart(3) == 2)
        #expect(PDFReaderNavigation.alignToSpreadStart(-5) == 0)
    }

    @Test("the document's own label is carried, not just the index")
    func carriesTheDocumentLabel() {
        // A book with roman front matter is "xii", not "12". Showing the index
        // in the page field is the small wrongness that makes a reader stop
        // trusting the page numbers.
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 11, label: "xii", count: 300, userInitiated: true)
        #expect(navigation.pageIndex == 11)
        #expect(navigation.pageLabel == "xii")
    }

    @Test("a programmatic move is not a user page turn")
    func distinguishesUserInitiatedMoves() {
        // This is the distinction the whole reading-position feature rests on:
        // restoring a saved position is not the user turning a page, and
        // recording it would make the resume point follow the act of opening
        // the book rather than the last place actually read.
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 4, label: "5", count: 100, userInitiated: false)
        #expect(!navigation.isUserInitiated)
        navigation.move(toPage: 5, label: "6", count: 100, userInitiated: true)
        #expect(navigation.isUserInitiated)
    }

    @Test("re-applying the same page does not publish again")
    func noOpMoveIsIgnored() {
        // Every page turn republishes the sidebar. Republishing on an unchanged
        // value — which happens whenever `PDFView` re-reports the page it is
        // already on — re-renders the whole sidebar mid-read.
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 4, label: "5", count: 100, userInitiated: true)
        #expect(navigation.pageIndex == 4)
        // A no-op must not even clear the user-initiated flag, or the flag
        // would depend on when the reader happened to ask.
        navigation.move(toPage: 4, label: "5", count: 100, userInitiated: false)
        #expect(navigation.isUserInitiated)
    }

    @Test("rotation wraps rather than accumulating")
    func rotationWraps() {
        let navigation = PDFReaderNavigation()
        #expect(navigation.rotationDegrees == 0)
        navigation.rotateClockwise()
        #expect(navigation.rotationDegrees == 90)
        navigation.rotateClockwise()
        navigation.rotateClockwise()
        navigation.rotateClockwise()
        // Four quarter turns is a full rotation, so the degrees are back to zero
        // rather than 360 — which is what PDFKit's absolute `rotation` wants.
        #expect(navigation.rotationDegrees == 0)
        navigation.rotateCounterClockwise()
        #expect(navigation.rotationDegrees == 270)
    }

    @Test("the page count can be updated without moving")
    func updatesCountAlone() {
        // A document whose real page count arrives after the first move, which
        // is every document: the count comes with the parse, and the reader can
        // be told to open a page before it has finished loading.
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 3, label: "iv", count: 10, userInitiated: true)
        navigation.update(label: "iv", count: 400)
        #expect(navigation.pageIndex == 3)
        #expect(navigation.pageCount == 400)
    }

    @Test("a move is clamped to the count known at the time")
    func clampsToTheCountItHas() {
        // With a placeholder count of 1, page 3 clamps to 0 — and the later
        // `update` does not retroactively move the reader back to 3. Restoring a
        // position the user never asked for is worse than starting at the top.
        let navigation = PDFReaderNavigation()
        navigation.move(toPage: 3, label: "iv", count: 1, userInitiated: true)
        #expect(navigation.pageIndex == 0)
        navigation.update(label: "iv", count: 400)
        #expect(navigation.pageIndex == 0)
    }
}

@Suite("PDF annotation vocabulary")
struct PDFAnnotationVocabularyTests {
    @Test("every kind maps to a PDF subtype and back")
    func subtypeRoundTrip() {
        for kind in PDFAnnotationKind.allCases {
            #expect(PDFAnnotationKind(subtype: kind.pdfSubtype) == kind)
        }
    }

    @Test("the subtypes are the ones Preview writes")
    func usesPreviewSubtypes() {
        // Not a cosmetic assertion: a highlight written as `/Subtype /HL` is
        // ignored by every reader, and one written as `/Subtype /Highlight` but
        // grouped under the wrong toolbar button is a different bug.
        #expect(PDFAnnotationKind.highlight.pdfSubtype == "Highlight")
        #expect(PDFAnnotationKind.underline.pdfSubtype == "Underline")
        #expect(PDFAnnotationKind.strikeOut.pdfSubtype == "StrikeOut")
        #expect(PDFAnnotationKind.square.pdfSubtype == "Square")
        #expect(PDFAnnotationKind.circle.pdfSubtype == "Circle")
        #expect(PDFAnnotationKind.note.pdfSubtype == "Text")
    }

    @Test("an unknown subtype is not coerced into a kind")
    func rejectsUnknownSubtypes() {
        // Popup and Link are legitimate PDF annotations. Mapping them onto one of
        // ours would show a link in the markup list as a highlight, and offer to
        // delete a link that is part of the document rather than the user's work.
        #expect(PDFAnnotationKind(subtype: "Link") == nil)
        #expect(PDFAnnotationKind(subtype: "Popup") == nil)
        #expect(PDFAnnotationKind(subtype: "Widget") == nil)
    }

    @Test("a note is a point and a highlight is a region")
    func regionRequirements() {
        // Getting this wrong means the user drags out a box to place a note and
        // nothing happens, because the gesture was consumed and no annotation was
        // created.
        #expect(!PDFAnnotationKind.note.needsRegion)
        #expect(!PDFAnnotationKind.line.needsRegion)
        for kind in PDFAnnotationKind.allCases where kind.needsRegion {
            #expect(kind != .note)
            #expect(kind != .line)
        }
    }

    @Test("every tool offers at least one kind and every kind one tool")
    func toolsAndKindsAgree() {
        for tool in PDFAnnotationTool.allCases {
            #expect(!tool.kinds.isEmpty, "\(tool.label) offers nothing")
            for kind in tool.kinds {
                #expect(kind.tool == tool)
            }
        }
        for kind in PDFAnnotationKind.allCases {
            #expect(PDFAnnotationTool.allCases.contains(kind.tool))
        }
    }

    @Test("a shape with no area is refused")
    func refusesDegenerateShapes() throws {
        // A zero-width rectangle is a valid *object* and an invalid annotation: no
        // reader will draw it, so writing one puts an entry in the page's
        // `/Annots` that renders as nothing.
        let page = PDFReference(number: 3, generation: 0)
        let empty = CGRect(x: 10, y: 10, width: 0, height: 20)
        #expect(
            PDFAnnotationFactory.dictionary(
                kind: .square, bounds: empty, colour: .yellow,
                contents: nil, identifier: "x", page: page
            ) == nil
        )
        let real = CGRect(x: 10, y: 10, width: 40, height: 12)
        #expect(
            PDFAnnotationFactory.dictionary(
                kind: .square, bounds: real, colour: .yellow,
                contents: nil, identifier: "x", page: page
            ) != nil
        )
    }

    @Test("a dictionary carries the identifier in both NM and T")
    func carriesTheIdentifier() throws {
        // PDFKit has no accessor for `/NM`, so the identifier also goes into
        // `/T`. Without that it cannot be found again after a reload, and
        // delete and edit become impossible.
        let dictionary = try #require(
            PDFAnnotationFactory.dictionary(
                kind: .highlight,
                bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                colour: .yellow,
                contents: nil,
                identifier: "amgi-Highlight-1234",
                page: PDFReference(number: 3, generation: 0)
            )
        )
        #expect(dictionary["NM"] != nil)
        #expect(dictionary["T"] != nil)
        #expect(dictionary["Subtype"]?.asName == "Highlight")
        #expect(dictionary["P"]?.asReference?.number == 3)
    }

    @Test("a highlight is written partly transparent")
    func highlightIsTranslucent() throws {
        // An opaque highlight hides the text it is marking, which is the one
        // thing a highlighter must not do.
        let dictionary = try #require(
            PDFAnnotationFactory.dictionary(
                kind: .highlight,
                bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                colour: .yellow,
                contents: nil,
                identifier: "x",
                page: PDFReference(number: 3, generation: 0)
            )
        )
        #expect(dictionary["CA"]?.asNumber ?? 1.0 < 1.0)
    }

    @Test("colours are distinct enough to tell apart")
    func coloursAreDistinguishable() {
        // Two colours that render near-identically make the swatch row a lie:
        // the user picks "green" and gets what they had before.
        for a in PDFAnnotationColour.allCases {
            for b in PDFAnnotationColour.allCases where a != b {
                let (ar, ag, ab) = a.rgb
                let (br, bg, bb) = b.rgb
                let distance = ((ar - br) * (ar - br)
                    + (ag - bg) * (ag - bg)
                    + (ab - bb) * (ab - bb)).squareRoot()
                #expect(distance > 0.1, "\(a.label) and \(b.label) are nearly identical")
            }
        }
    }
}

@Suite("PDF draft region")
struct PDFDraftRegionTests {
    @Test("a drag in any direction gives a positive rectangle")
    func normalisesTheRectangle() {
        // A rectangle built from two arbitrary points has a negative width when
        // the drag runs right-to-left, and a negative width is not a valid
        // annotation rectangle: the file records it and nothing draws it.
        let forward = PDFDraftRegion(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 110, y: 40))
        #expect(forward.rect.origin == CGPoint(x: 10, y: 10))
        #expect(forward.rect.width == 100)

        let backward = PDFDraftRegion(start: CGPoint(x: 110, y: 40), current: CGPoint(x: 10, y: 10))
        #expect(backward.rect.origin == CGPoint(x: 10, y: 10))
        #expect(backward.rect.width == 100)
        #expect(backward.rect == forward.rect)
    }

    @Test("an accidental tap is not an annotation")
    func rejectsAccidentalTaps() {
        // Writing a zero-area annotation for a stray touch is how a page fills up
        // with invisible marks the user cannot find or delete.
        let tap = PDFDraftRegion(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 51, y: 51))
        #expect(!tap.isMeaningful)
        let drag = PDFDraftRegion(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 150, y: 90))
        #expect(drag.isMeaningful)
    }
}
