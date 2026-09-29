public import Foundation

/// Which side of a card a piece of content belongs to.
///
/// A flat string rather than an index into the notetype's fields, because the
/// notetype can be reordered by the user in the browser and a card parked
/// against an ordinal would silently swap sides. The name is the contract.
public enum PDFCardSide: String, Codable, Sendable, Hashable, CaseIterable {
    case front
    case back

    /// The other side. Used by the menu to offer the pair at once.
    var opposite: PDFCardSide { self == .front ? .back : .front }
}

/// Where a side's content came from.
///
/// Load-bearing rather than a convenience. A selection is a quotation of the
/// page and can be re-found later; a typed line cannot. Presenting the two
/// identically would let a hand-written guess be read back as something the
/// book says, which is the one mistake a card must not make.
public enum PDFCardProvenance: Codable, Sendable, Hashable {
    /// Taken from a text selection or a dragged region.
    case selection(PDFCardSelection)
    /// Written by the user.
    case typed(String)
}

/// A selection or a region, anchored back into the document.
public struct PDFCardSelection: Codable, Sendable, Hashable {
    /// The text as read. Empty for a region that covered no selectable text,
    /// which is the normal case for a figure or a formula.
    public var quote: String
    public var anchor: PDFSourceAnchor
    /// Filename of a cropped region image, or nil when none was captured.
    public var regionMediaName: String?
    /// The document's own page label — "xii", not "12".
    public var pageLabel: String

    public init(
        quote: String,
        anchor: PDFSourceAnchor,
        regionMediaName: String? = nil,
        pageLabel: String
    ) {
        self.quote = quote
        self.anchor = anchor
        self.regionMediaName = regionMediaName
        self.pageLabel = pageLabel
    }
}

/// One piece of content on one side of a card.
///
/// A card is a list of these rather than a pair of strings, because the two
/// things a reader actually does — quote three phrases in a row, and come back
/// tomorrow to add a fourth — both need somewhere to put the third and the
/// fourth. A two-string card has exactly one slot per side and loses both.
public struct PDFCardAppending: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var side: PDFCardSide
    public var provenance: PDFCardProvenance

    public init(
        id: UUID = UUID(),
        side: PDFCardSide,
        provenance: PDFCardProvenance
    ) {
        self.id = id
        self.side = side
        self.provenance = provenance
    }

    /// The text to show, whichever provenance it came from.
    ///
    /// Computed, not stored: a cached copy would be a second source of truth
    /// that could disagree with the provenance after a decode, and a card whose
    /// text and provenance disagree is worse than either being alone.
    public var displayText: String {
        switch provenance {
        case .selection(let selection):
            let quote = selection.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            // A region over a figure has no text. The image is the content, and
            // showing a placeholder in the text field would push the reader to
            // remember what the picture was.
            return quote.isEmpty ? "" : quote
        case .typed(let text):
            return text
        }
    }

    /// The anchor, when this appending came from the document.
    public var anchor: PDFSourceAnchor? {
        guard case .selection(let selection) = provenance else { return nil }
        return selection.anchor
    }

    /// The cropped region filename, when one was captured for this appending.
    public var regionMediaName: String? {
        guard case .selection(let selection) = provenance else { return nil }
        return selection.regionMediaName
    }

    /// Whether this appending has anything a user would recognise as content.
    ///
    /// A region with no text and no image is an empty drag, and appending it
    /// would make a card that looks complete in the park list and renders blank
    /// in review.
    public var hasContent: Bool {
        if regionMediaName != nil { return true }
        return !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
