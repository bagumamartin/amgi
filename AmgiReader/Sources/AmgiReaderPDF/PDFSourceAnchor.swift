public import Foundation

/// A durable pointer back to a place in a PDF.
///
/// PDFs are *position*-first documents, which makes their anchors a different
/// problem from EPUB's text-first ones. In an EPUB the words are stable and
/// the layout is not, so a card stores the quote and re-finds the passage by
/// searching for it. In a PDF there is no reflow: a paragraph on page 340 is a
/// fixed set of glyphs at fixed coordinates, and the page number is intrinsic
/// and meaningful to a human.
///
/// But neither half is trustworthy alone:
///
/// - **Page alone** breaks when the PDF is regenerated. Re-running "print to
///   PDF", or opening the same source in a different toolchain, repaginates.
/// - **Coordinates alone** break for the same reason, and additionally across
///   zoom and rotation.
/// - **The quote alone** is the only stable handle, and it can be ambiguous
///   when a phrase repeats.
///
/// So an anchor carries all three, and a resolution that cannot confirm the
/// quote on the expected page must fail *loudly* rather than point at whatever
/// happened to be nearby. A card citing the wrong paragraph is worse than a
/// card that admits it lost its place.
public struct PDFSourceAnchor: Codable, Sendable, Hashable {
    /// Schema version, so a future migration can tell shapes apart.
    public var version: Int

    /// Book the anchor points into.
    public var bookID: String

    /// Zero-based page index. Stable for a given file; that is precisely why
    /// it is paired with `documentFingerprint` rather than trusted alone.
    public var pageIndex: Int

    /// The document's own page label — "xii" in roman front matter, "340" in
    /// the body. Carried so a card can show the number a reader would say out
    /// loud, and so roman/arabic schemes survive without re-deriving them.
    public var pageLabel: String?

    /// Region on the page, normalised to 0...1 of the page box.
    ///
    /// Normalised rather than in PDF points so the anchor survives a re-export
    /// at a different page size. It does *not* survive a different crop box,
    /// which is one of the cases `documentFingerprint` catches.
    public var rect: PDFNormalizedRect?

    /// The text as it was read, for verification on re-open.
    public var quote: String
    /// Surrounding text, used to disambiguate a repeated quote.
    public var contextBefore: String?
    public var contextAfter: String?

    /// Identifies *this* document, not merely this book entry.
    ///
    /// A fingerprint over the page geometry and a content sample rather than
    /// the whole file: hashing 400 pages to detect a repagination is not worth
    /// it, and the geometry sample is what actually changes when a PDF is
    /// regenerated. When it no longer matches, the anchor is reported as stale
    /// instead of being silently trusted.
    public var documentFingerprint: String

    /// Where the selection came from.
    ///
    /// This distinction is load-bearing. A `.ocr` quote is a machine guess, so
    /// a card built from one is presented differently (image region first,
    /// recognised text as a hint) and carries the recognition confidence. A
    /// single anchor type with a `confidence` field would let a low-confidence
    /// OCR result masquerade as exact text.
    public enum Origin: String, Codable, Sendable, Hashable {
        /// From the PDF's own text layer — exact.
        case textLayer
        /// From Vision text recognition over a rendered page — approximate.
        case ocr
    }

    public var origin: Origin

    /// Recognition confidence, 0...1. Present only for `.ocr`.
    public var confidence: Double?

    public var createdAt: Date

    public init(
        version: Int = PDFSourceAnchor.currentVersion,
        bookID: String,
        pageIndex: Int,
        pageLabel: String? = nil,
        rect: PDFNormalizedRect? = nil,
        quote: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        documentFingerprint: String,
        origin: Origin = .textLayer,
        confidence: Double? = nil,
        createdAt: Date = .now
    ) {
        self.version = version
        self.bookID = bookID
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.rect = rect
        self.quote = quote
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.documentFingerprint = documentFingerprint
        self.origin = origin
        self.confidence = confidence
        self.createdAt = createdAt
    }

    public static let currentVersion = 1

    /// Number of characters of context captured either side, matching the Web
    /// Annotation `TextQuoteSelector` recommendation so the sidecar this
    /// eventually projects from is a straight mapping.
    public static let contextCharacterCount = 32

    /// Minimum OCR confidence for a card to be offered at all.
    ///
    /// Below this the recognised text is not trustworthy enough to put in front
    /// of a learner as though it were what the page said. The region image is
    /// still shown; the text is shown as a hint.
    public static let minimumCardConfidence = 0.55

    /// Whether a card may be built from this anchor.
    ///
    /// A text-layer anchor always may. An OCR anchor may only above the
    /// confidence floor.
    public var supportsCardCreation: Bool {
        switch origin {
        case .textLayer: true
        case .ocr: (confidence ?? 0) >= Self.minimumCardConfidence
        }
    }

    /// The page number a human would recognise.
    public var displayPageLabel: String {
        pageLabel ?? String(pageIndex + 1)
    }

    /// Normalises text for quote comparison, so a re-extraction that reflows a
    /// line break does not defeat verification.
    public static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A rectangle in page-relative units.
///
/// PDF user space has its origin at the bottom-left with y increasing upward,
/// while every UI framework this app draws in has its origin at the top-left
/// with y increasing downward. Storing raw PDF points would therefore make
/// the anchor depend on which framework rendered it. This normalises both
/// axes to 0...1 from the *top* left, which is what the renderer and the crop
/// code both think in.
public struct PDFNormalizedRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Converts a rect in PDF user space (origin bottom-left) on a page of the
    /// given size into this normalised top-left form.
    public init(pdfRect: PDFRect, pageWidth: Double, pageHeight: Double) {
        guard pageWidth > 0, pageHeight > 0 else {
            self.init(x: 0, y: 0, width: 0, height: 0)
            return
        }
        // Clamp before normalising: a selection that overhangs the page box
        // (common for a whole-paragraph selection) must not produce a
        // coordinate outside 0...1, or the crop code would sample off-page.
        let minX = min(max(pdfRect.x, 0), pageWidth)
        let maxX = min(max(pdfRect.x + pdfRect.width, 0), pageWidth)
        let minY = min(max(pdfRect.y, 0), pageHeight)
        let maxY = min(max(pdfRect.y + pdfRect.height, 0), pageHeight)
        self.init(
            x: minX / pageWidth,
            y: 1 - (maxY / pageHeight),
            width: max(0, (maxX - minX) / pageWidth),
            height: max(0, (maxY - minY) / pageHeight)
        )
    }

    /// Back to PDF user space on a page of the given size.
    public func pdfRect(pageWidth: Double, pageHeight: Double) -> PDFRect {
        PDFRect(
            x: x * pageWidth,
            y: pageHeight - (y + height) * pageHeight,
            width: width * pageWidth,
            height: height * pageHeight
        )
    }

    /// Whether the rect actually encloses any area.
    ///
    /// A zero-area rect cannot be cropped or hit-tested, so it is treated as
    /// absent rather than passed downstream to fail obscurely.
    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    public var isValid: Bool {
        let inUnitRange = (0...1).contains(x) && (0...1).contains(y)
            && (0...1).contains(x + width) && (0...1).contains(y + height)
        return inUnitRange && !isEmpty
    }
}

/// A rectangle in PDF user space, expressed without depending on CoreGraphics
/// so the domain layer stays platform-light.
public struct PDFRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
