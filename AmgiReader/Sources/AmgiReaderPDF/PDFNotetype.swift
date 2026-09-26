import Foundation

/// The field contract for the dedicated PDF notetype.
///
/// A separate notetype — rather than reusing the EPUB one — because a PDF card
/// is not a text card. It can carry a cropped image of a figure, table, or
/// formula, which reflowable text has no equivalent of, and it shows a page
/// number that means something to a reader. Both are structural, not
/// cosmetic, so they belong in the template rather than bolted onto a shared
/// one as unused columns.
public enum PDFNotetype {
    /// The notetype's name, as it appears in Anki.
    public static let name = "IJUKA PDF"

    /// The model this expects to find. Anki models are the same for
    /// recognition-sourced and typed-sourced decks alike; the field *layout* is
    /// what differs.
    public static let modelName = "Basic"

    /// Fields, in order. The first is the prompt.
    ///
    /// Kept short deliberately: every field is a column the user has to look
    /// at in the browser, and every one is a chance to leave a blank that
    /// shows up as an empty gap in review.
    public enum Field: String, CaseIterable, Sendable {
        /// Prompt — the term or question.
        case term
        /// The sentence the term was taken from.
        case sentence
        /// The document's own page label, e.g. "340" or "xii".
        case page
        /// A cropped image of the source region, stored in the media folder.
        case region
        /// Encoded `PDFSourceAnchor`, so the app can re-open the card at the
        /// exact spot rather than searching for the quote again.
        case source

        public var name: String {
            switch self {
            case .term: "Term"
            case .sentence: "Sentence"
            case .page: "Page"
            case .region: "Region"
            case .source: "Source"
            }
        }

        /// Whether the field is a prompt.
        public var isPrompt: Bool { self == .term }
    }

    /// All field names in order.
    public static var fieldNames: [String] {
        Field.allCases.map(\.name)
    }

    /// Media folder prefix for cropped regions.
    ///
    /// Prefixed and content-addressed so re-capturing the same region reuses
    /// the same file instead of accumulating near-duplicates in the user's
    /// media folder.
    public static let regionMediaPrefix = "amgi-pdf-region"

    /// Media filename for a captured region.
    public static func regionMediaName(documentFingerprint: String, anchorID: String) -> String {
        // 12 hex characters of the fingerprint is plenty to separate documents
        // while keeping the filename short enough to read in a file listing.
        let document = PDFDocumentFingerprint.short(documentFingerprint)
        return "\(regionMediaPrefix)_\(document)_\(anchorID).png"
    }
}

/// A card built from a PDF selection, ready to be projected onto the
/// notetype's fields.
///
/// Separate from the note draft the EPUB reader produces, because the two
/// differ in ways that matter: a PDF card has a page and possibly an image,
/// and its sentence may be machine-read rather than exact.
public struct PDFCardPayload: Sendable, Hashable {
    /// The word or phrase the card is about.
    public var term: String
    /// The sentence containing it.
    public var sentence: String
    /// The document's own page label.
    public var pageLabel: String
    /// The encoded anchor, for re-opening the card at its source.
    public var anchor: PDFSourceAnchor
    /// Filename of a cropped region image, when one was captured.
    public var regionMediaName: String?
    /// Text as recognised, where it came from OCR and may be unreliable.
    public var isRecognisedText: Bool
    /// Recognition confidence, 0...1, for recognised text.
    public var confidence: Double?

    public init(
        term: String,
        sentence: String,
        pageLabel: String,
        anchor: PDFSourceAnchor,
        regionMediaName: String? = nil,
        isRecognisedText: Bool = false,
        confidence: Double? = nil
    ) {
        self.term = term
        self.sentence = sentence
        self.pageLabel = pageLabel
        self.anchor = anchor
        self.regionMediaName = regionMediaName
        self.isRecognisedText = isRecognisedText
        self.confidence = confidence
    }

    /// Whether this payload may be turned into a card at all.
    public var isCardWorthy: Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && anchor.supportsCardCreation
    }

    /// The field values, in `PDFNotetype.Field` order.
    ///
    /// Optional fields are *omitted* rather than written empty: an empty
    /// column is visible in Anki's browser and in the editor, so a card with
    /// no region should not carry a blank Region field.
    public func fieldValues() -> [(field: String, value: String)] {
        var out: [(field: String, value: String)] = []
        out.append((PDFNotetype.Field.term.name, term))
        out.append((PDFNotetype.Field.sentence.name, sentence))
        out.append((PDFNotetype.Field.page.name, pageLabel))
        if let regionMediaName {
            out.append((PDFNotetype.Field.region.name, regionMediaName))
        }
        out.append((PDFNotetype.Field.source.name, encodedAnchor()))
        return out
    }

    /// The anchor as compact JSON, for the Source field.
    public func encodedAnchor() -> String {
        guard let data = try? JSONEncoder().encode(anchor),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    /// How the sentence should be presented in review.
    ///
    /// Recognised text is a guess. Presenting it in the same weight as the
    /// term would teach the learner that a misread word is what the book says,
    /// so a low-confidence card is marked as recognised and keeps the region
    /// image as the authority.
    public var carriesUncertainTextWarning: Bool {
        isRecognisedText && (confidence ?? 0) < PDFSourceAnchor.minimumCardConfidence
    }
}
