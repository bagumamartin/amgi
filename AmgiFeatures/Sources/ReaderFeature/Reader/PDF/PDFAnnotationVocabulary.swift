import AmgiReader
import AmgiReaderPDF
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI

/// The markup tools, matching Preview's set.
///
/// Named for what they *are* on the page rather than for the tool that made
/// them, because the same term has to survive a round trip through the PDF, a
/// sync to another device, and a hand-off to Preview. "Highlight" is a
/// `/Subtype`; "Pen" is a colour and a width, which is why freehand and
/// straight-line shapes are one kind with a colour and a width rather than
/// several kinds.
enum PDFAnnotationKind: String, CaseIterable, Identifiable, Sendable {
    case highlight
    case underline
    case strikeOut
    case square
    case circle
    case line
    case ink
    case note
    case freeText

    var id: String { rawValue }

    /// The `/Subtype` written into the PDF.
    var pdfSubtype: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "StrikeOut"
        case .square: "Square"
        case .circle: "Circle"
        case .line: "Line"
        case .ink: "Ink"
        case .note: "Text"
        case .freeText: "FreeText"
        }
    }

    var tool: PDFAnnotationTool {
        switch self {
        case .highlight, .underline, .strikeOut: .marker
        case .square, .circle, .line: .shape
        case .ink: .pen
        case .note: .note
        case .freeText: .text
        }
    }

    var label: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strike Out"
        case .square: "Rectangle"
        case .circle: "Ellipse"
        case .line: "Line"
        case .ink: "Pen"
        case .note: "Note"
        case .freeText: "Text Box"
        }
    }

    var symbolName: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .square: "rectangle"
        case .circle: "circle"
        case .line: "line.diagonal"
        case .ink: "scribble"
        case .note: "note.text"
        case .freeText: "textformat"
        }
    }

    /// Whether this kind needs a dragged region rather than a point.
    ///
    /// A note is a pin dropped at a point; a line is a drag between two points;
    /// everything else is a region. Getting this wrong means the user drags out
    /// a box to place a note and gets nothing, because the gesture consumed the
    /// drag and no annotation was created.
    var needsRegion: Bool {
        switch self {
        case .highlight, .underline, .strikeOut, .square, .circle, .ink, .freeText: true
        case .line, .note: false
        }
    }

    init?(subtype: String) {
        guard let match = Self.allCases.first(where: { $0.pdfSubtype == subtype })
        else { return nil }
        self = match
    }
}

/// The toolbar groups, matching Preview's arrangement.
///
/// Grouped rather than one flat list of ten because that is how Preview does it,
/// and the grouping is the only thing that makes ten options learnable: the user
/// picks a *kind of mark* first and a style second.
enum PDFAnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case marker
    case shape
    case pen
    case note
    case text
    /// Not a markup tool. The one tool whose drag does not make an annotation:
    /// it makes a card selection, which is a different verb entirely and has
    /// its own drag semantics. It lives in this enum because the toolbar is a
    /// row of mutually-exclusive tools and a second row would be a second place
    /// to look.
    case card

    var id: String { rawValue }

    var label: String {
        switch self {
        case .marker: "Highlight"
        case .shape: "Shapes"
        case .pen: "Draw"
        case .note: "Note"
        case .text: "Text"
        case .card: "Card"
        }
    }

    var symbolName: String {
        switch self {
        case .marker: "highlighter"
        case .shape: "square.on.circle"
        case .pen: "pencil.tip"
        case .note: "note.text"
        case .text: "textformat"
        case .card: "rectangle.portrait.on.rectangle.portrait"
        }
    }

    var kinds: [PDFAnnotationKind] {
        switch self {
        case .marker: [.highlight, .underline, .strikeOut]
        case .shape: [.square, .circle, .line]
        case .pen: [.ink]
        case .note: [.note]
        case .text: [.freeText]
        // A card is a region, and the nearest existing kind describes that
        // shape. Reusing `.square` rather than adding a kind that maps to no PDF
        // `/Subtype` keeps the annotation round-trip honest: the card path
        // intercepts the drag before any annotation is built, so this kind is
        // never written to a file.
        case .card: [.square]
        }
    }

    /// Whether this tool writes markup into the document.
    ///
    /// False for the card tool, and the distinction is load-bearing in two
    /// places: the toolbar must not offer a colour for a tool that has none,
    /// and the drag gesture must not consume a drag that ends up making an
    /// annotation. A card drag shows the selection menu instead.
    var makesAnnotations: Bool {
        self != .card
    }
}

/// The colours Preview offers for markup.
///
/// Named, and with a stable identifier, because the name is what has to survive
/// into the file. `/C` is an RGB array, and a colour that round-trips as "some
/// yellow" is indistinguishable from every other yellow — so the label travels
/// with the annotation rather than being inferred from the numbers each time.
enum PDFAnnotationColour: String, CaseIterable, Identifiable, Sendable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case grey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        case .grey: "Grey"
        }
    }

    /// The RGB triple written into `/C`.
    ///
    /// Preview's own values, because a user who has annotated in Preview expects
    /// to see the same yellow here. Inventing different ones would make one
    /// highlight look like two marks depending on which app drew it.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .yellow: (1.0, 0.82, 0.0)
        case .green: (0.44, 0.86, 0.44)
        case .blue: (0.40, 0.64, 0.95)
        case .pink: (1.0, 0.45, 0.55)
        case .purple: (0.65, 0.50, 0.90)
        case .grey: (0.65, 0.65, 0.65)
        }
    }

    var pdfArray: [Double] {
        let (r, g, b) = rgb
        return [r, g, b]
    }
}

/// One annotation as the reader needs to show it.
///
/// A value type built from PDFKit's annotation, so the sidebar can render
/// without holding live PDFKit objects and the list can diff cheaply.
struct PDFPageAnnotation: Identifiable, Equatable, Sendable {
    let id: String
    let kind: PDFAnnotationKind
    let colour: PDFAnnotationColour
    let bounds: CGRect
    let contents: String?
    let pageIndex: Int
    let modified: Date?

    init?(pdfAnnotation: PDFAnnotation, pageIndex: Int) {
        guard let subtype = pdfAnnotation.type,
              let kind = PDFAnnotationKind(subtype: subtype)
        else { return nil }
        // `userName` carries our identifier, because PDFKit exposes no accessor
        // for `/NM` — the field every conforming reader actually uses to name an
        // annotation. `/T` is nominally the author, is ignored by other readers'
        // interfaces, and is the one string PDFKit round-trips, so it is where
        // the identifier goes. Without it there is no way to find an annotation
        // again after a reload, which makes delete and edit impossible.
        //
        // A nil `userName` means the annotation did not come from us — it was
        // added in Preview, or by another tool. It is still listed, keyed by its
        // page and position, because the user can see it in the document and a
        // sidebar that omits visible markup is worse than one that cannot
        // delete a particular item.
        let identifier = pdfAnnotation.userName
            ?? "foreign-\(pageIndex)-\(Int(pdfAnnotation.bounds.minX))-\(Int(pdfAnnotation.bounds.minY))"
        self.id = identifier
        self.kind = kind
        self.colour = PDFAnnotationColour(pdfAnnotation: pdfAnnotation) ?? .yellow
        self.bounds = pdfAnnotation.bounds
        self.contents = pdfAnnotation.contents
        self.pageIndex = pageIndex
        self.modified = pdfAnnotation.modificationDate
    }
}

extension PDFAnnotationColour {
    /// The nearest offered colour for an annotation's `/C`.
    ///
    /// Matched by distance rather than equality because a colour that has been
    /// through another tool, a sync, or a different colour profile is never
    /// exactly one of ours. Snapping to the nearest is what stops the filter
    /// showing a swatch that is not in the list.
    init?(pdfAnnotation: PDFAnnotation) {
        let components = pdfAnnotation.color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        components.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        guard let best = PDFAnnotationColour.allCases.min(by: { a, b in
            a.distance(to: red, green: green, blue: blue)
                < b.distance(to: red, green: green, blue: blue)
        }) else { return nil }
        // Beyond a generous threshold the colour is somebody else's entirely — a
        // red cross-reference mark, say — and labelling it "Yellow" in a filter
        // is a lie the user cannot see through.
        let threshold: CGFloat = 0.45
        guard best.distance(to: red, green: green, blue: blue) < threshold else { return nil }
        self = best
    }

    private func distance(to red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let (r, g, b) = rgb
        let dr = CGFloat(r) - red
        let dg = CGFloat(g) - green
        let db = CGFloat(b) - blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    var swiftUIColor: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }
}

/// An entry in the sidebar's bookmark list.
struct PDFBookmark: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let pageIndex: Int
    let depth: Int
    /// Whether the entry resolves to a page at all.
    ///
    /// A PDF outline entry may point at a named destination that does not exist,
    /// or at a page in a file that is not present. Such an entry is listed
    /// because the user can see it in the document, but tapping it cannot go
    /// anywhere, and a row that does nothing when tapped is worse than a row
    /// that says so.
    let hasDestination: Bool
}

/// Builds PDFKit annotations and the matching PDF dictionaries.
///
/// Both from one place on purpose. The two must agree: a highlight PDFKit draws
/// at one rectangle and the file records at another is a highlight the user can
/// see and cannot find, and it only shows up after a reload. Deriving both from
/// the same inputs is what keeps them in step.
enum PDFAnnotationFactory {
    /// A PDFKit annotation for the live document.
    static func make(
        kind: PDFAnnotationKind,
        bounds: CGRect,
        colour: PDFAnnotationColour,
        contents: String?,
        identifier: String
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: pdfKitSubtype(for: kind),
            withProperties: nil
        )
        annotation.color = colour.platformColor
        if let contents, !contents.isEmpty {
            annotation.contents = contents
        }
        annotation.userName = identifier
        return annotation
    }

    /// The PDF dictionary for the same annotation, in PDF user space.
    ///
    /// Returns nil for a shape with no area, which cannot be written: a
    /// zero-width rectangle in a file is an annotation no reader will draw, so
    /// it is refused here, where the caller can still report it.
    static func dictionary(
        kind: PDFAnnotationKind,
        bounds: CGRect,
        colour: PDFAnnotationColour,
        contents: String?,
        identifier: String,
        page: PDFReference
    ) -> PDFDictionary? {
        guard bounds.width > 0, bounds.height > 0 || kind == .line else { return nil }
        var dictionary = PDFDictionary()
        dictionary["Type"] = .name("Annot")
        dictionary["Subtype"] = .name(kind.pdfSubtype)
        dictionary["Rect"] = .array([
            .integer(Int(bounds.minX.rounded())),
            .integer(Int(bounds.minY.rounded())),
            .integer(Int(bounds.maxX.rounded())),
            .integer(Int(bounds.maxY.rounded())),
        ])
        dictionary["Contents"] = .string(
            bytes: PDFStringLiteral.utf16(contents ?? "").bytes,
            isHex: false
        )
        dictionary["P"] = .reference(page)
        dictionary["C"] = .array(colour.pdfArray.map { .real($0) })
        // `/NM` is the annotation's unique name and the field every conforming
        // reader uses to identify it. PDFKit cannot read it back, which is why
        // the same value also goes into `/T`.
        dictionary["NM"] = .string(bytes: Array(identifier.utf8), isHex: false)
        dictionary["T"] = .string(bytes: Array(identifier.utf8), isHex: false)
        // Transparency. Preview's highlighter is partly transparent, and an
        // opaque one hides the text it is meant to mark.
        dictionary["CA"] = .real(kind == .highlight ? 0.4 : 1.0)
        return dictionary
    }

    private static func pdfKitSubtype(for kind: PDFAnnotationKind) -> PDFAnnotationSubtype {
        switch kind {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        case .square: .square
        case .circle: .circle
        case .line: .line
        case .ink: .ink
        case .note: .text
        case .freeText: .freeText
        }
    }
}

/// Represents the text or region selected by the user in a PDF.
struct PDFSelectionContext: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case textSelection
        case region(dragRect: PDFNormalizedRect)
    }

    struct Details: Sendable {
        let bookID: String
        let documentFingerprint: String
        let pageLabel: @Sendable (Int) -> String
    }

    let text: String
    let anchor: PDFSourceAnchor
    let regionRect: PDFNormalizedRect
    let pageBounds: CGRect?
    let pageIndex: Int
    let pageLabel: String
    let source: Source

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
