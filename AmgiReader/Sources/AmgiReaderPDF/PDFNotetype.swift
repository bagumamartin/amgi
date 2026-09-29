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

    /// The card template's name.
    ///
    /// Anki generates one card per template, so a rename here changes how many
    /// cards every existing note of this type makes.
    public static let templateName = "Card 1"

    /// Fields, in order. The first is the prompt.
    ///
    /// `Front` and `Back` rather than `Term` and `Sentence`, because a card here
    /// is assembled by appending: neither side is one term or one sentence
    /// anymore, and a field named for the single value it used to hold
    /// misdescribes every card made after the first append.
    public enum Field: String, CaseIterable, Sendable {
        /// Prompt — every front appending, joined.
        case front
        /// Answer — every back appending, joined.
        case back
        /// Every page the card draws on, comma-separated.
        case page
        /// Region image filenames, space-separated.
        case region
        /// Encoded anchors, so the app can re-open the card at its source.
        case source

        public var name: String {
            switch self {
            case .front: "Front"
            case .back: "Back"
            case .page: "Page"
            case .region: "Region"
            case .source: "Source"
            }
        }

        /// Whether the field is a prompt.
        public var isPrompt: Bool { self == .front }
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

    /// The question side of the card template.
    ///
    /// The region image goes on the *question* side deliberately. A card built
    /// from a figure is asking "what is this?" — showing the figure on the
    /// answer side only would leave the prompt reading "which of these does
    /// this refer to?" with nothing to refer to.
    public static let questionFormat = """
    <div class="amgi-pdf-card">
      {{#Region}}<div class="amgi-pdf-regions">{{Media: Region}}</div>{{/Region}}
      <div class="amgi-pdf-front">{{Front}}</div>
    </div>
    """

    /// The answer side of the card template.
    public static let answerFormat = """
    <div class="amgi-pdf-card">
      {{#Region}}<div class="amgi-pdf-regions">{{Media: Region}}</div>{{/Region}}
      <div class="amgi-pdf-front">{{Front}}</div>
    </div>
    <hr id="answer">
    <div class="amgi-pdf-back">{{Back}}</div>
    {{#Page}}<div class="amgi-pdf-meta">Page {{Page}}</div>{{/Page}}
    """

    /// Styling for the card template.
    ///
    /// Only what the field layout needs. Anki's own Basic styles already handle
    /// text, and overriding them wholesale is how a user who has tuned their
    /// collection's CSS ends up with cards that ignore it.
    public static let css = """
    .amgi-pdf-card { text-align: left; }
    .amgi-pdf-front, .amgi-pdf-back { white-space: pre-wrap; }
    .amgi-pdf-regions { margin-bottom: 0.6em; }
    .amgi-pdf-regions img { max-width: 100%; height: auto; border-radius: 4px; }
    .amgi-pdf-meta { margin-top: 0.8em; font-size: 0.75em; opacity: 0.6; text-align: right; }
    """
}

/// A card built from a PDF selection, projected onto the notetype's fields.
///
/// A **projection of appendings** rather than a single selection, because that
/// is what a card is by the time it is worth writing: the user has usually
/// quoted more than one thing, and a projection that could only represent one
/// would have to drop the rest or refuse the card. Both are worse than a longer
/// field.
public struct PDFCardPayload: Sendable, Hashable {
    /// Front appendings, in the order the user added them.
    public var front: [PDFCardAppending]
    /// Back appendings, in the order the user added them.
    public var back: [PDFCardAppending]

    public init(front: [PDFCardAppending], back: [PDFCardAppending]) {
        self.front = front
        self.back = back
    }

    /// Every appending, fronts first.
    ///
    /// The order is what `Source.primary` is derived from, and it is
    /// deterministic on purpose: the anchor the app re-opens the card at must
    /// not depend on dictionary iteration order.
    public var allAppendings: [PDFCardAppending] { front + back }

    /// Whether this payload can become a note at all.
    ///
    /// A card with no front cannot generate a card in Anki, so it is refused
    /// here rather than written as a note that silently produces nothing. A
    /// missing *back* is not a reason to refuse: Anki renders a one-sided card
    /// fine, and a card that is only an example sentence is still worth
    /// keeping. Refusing loses the appendings, which are the real work.
    public var isCardWorthy: Bool {
        front.contains { $0.hasContent }
    }

    /// The values as a dictionary, keyed by field name.
    ///
    /// The form a note draft takes, and the form the editor works in. A field
    /// that has nothing to say is **absent** rather than present-and-blank: a
    /// blank column is visible in Anki's browser and in the editor, so a
    /// text-only card should not carry an empty Region field for the user to
    /// wonder about.
    ///
    /// `Front` and `Back` are the exception — they are always present, empty or
    /// not, because they are the two halves the notetype is built around and a
    /// card missing one of them from the draft entirely is harder to edit than
    /// one showing an empty side.
    public func fieldValueDictionary() -> [String: String] {
        var out: [String: String] = [
            PDFNotetype.Field.front.name: joinedText(front),
            PDFNotetype.Field.back.name: joinedText(back),
        ]
        let pages = pageList()
        if !pages.isEmpty { out[PDFNotetype.Field.page.name] = pages }
        let regions = regionList()
        if !regions.isEmpty { out[PDFNotetype.Field.region.name] = regions }
        let source = encodedSource()
        if !source.isEmpty { out[PDFNotetype.Field.source.name] = source }
        return out
    }

    /// The values as a positional array, for a direct note write.
    ///
    /// `NewNoteTemplate.fields` is indexed by the notetype's field ordinals
    /// rather than by name, so a field that is *absent* from the dictionary
    /// above still occupies its slot here as an empty string. A short array does
    /// not skip a field — it shifts every field after the gap into the wrong
    /// column, which is how "Page" ends up in "Source". This is the one place
    /// an empty string is correct, and it is correct only because the array is
    /// positional.
    ///
    /// The length is also forced to the notetype's field count even when the
    /// caller's list is shorter, so a notetype with an extra trailing field
    /// cannot receive a note that is one column short.
    public func orderedFieldValues(against fieldNames: [String]) -> [String] {
        let values = fieldValueDictionary()
        return fieldNames.map { values[$0] ?? "" }
    }

    /// Every page the card draws on, comma-separated and de-duplicated.
    ///
    /// *Every* page, not the first. A card assembled from page 12 and page 340
    /// that cites "page 12" is not a small inaccuracy — it points the reader at
    /// the wrong place, which is the only thing the page number is for.
    public func pageList() -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for appending in allAppendings {
            guard let anchor = appending.anchor else { continue }
            let label = anchor.displayPageLabel
            // First mention wins: a card quoting three phrases from page 12
            // should read "12", not "12, 12, 12".
            if seen.insert(label).inserted {
                ordered.append(label)
            }
        }
        return ordered.joined(separator: ", ")
    }

    /// Region image filenames, space-separated.
    ///
    /// Space-separated because that is what Anki's `{{Media: field}}` filter
    /// parses. Several filenames in one field is lossless, and the template
    /// renders them all; the single-region case, which is most of them, is
    /// unaffected.
    public func regionList() -> String {
        allAppendings.compactMap(\.regionMediaName).joined(separator: " ")
    }

    /// The `Source` field: the primary anchor, then every anchor.
    ///
    /// `primary` is the *first* appending's anchor rather than the first page's
    /// or the longest quote's, because "reopen this card at its source" has to
    /// be unambiguous and the user made the first one first. The rest go in
    /// `all` rather than being dropped: a card with two anchors and one field
    /// value loses the second source entirely.
    public func encodedSource() -> String {
        let anchors = allAppendings.compactMap(\.anchor)
        guard let primary = anchors.first else { return "" }
        let source = PDFCardSource(primary: primary, all: anchors)
        guard let data = try? JSONEncoder().encode(source),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    /// The anchors, in projection order.
    public var anchors: [PDFSourceAnchor] { allAppendings.compactMap(\.anchor) }

    /// Whether any appending came from OCR rather than the text layer.
    ///
    /// Recognised text is a guess. Presenting it in the same weight as the term
    /// would teach the learner that a misread word is what the book says, so a
    /// low-confidence card keeps the region image as the authority and says so.
    public var carriesUncertainTextWarning: Bool {
        anchors.contains { anchor in
            anchor.origin == .ocr
                && (anchor.confidence ?? 0) < PDFSourceAnchor.minimumCardConfidence
        }
    }

    /// Appendings joined with a newline, not concatenated.
    ///
    /// Concatenation produces "the quickbrown fox" from "the quick" and "brown
    /// fox", and the missing space is invisible until the card is in review.
    private func joinedText(_ appendings: [PDFCardAppending]) -> String {
        appendings
            .filter(\.hasContent)
            .map(\.displayText)
            .joined(separator: "\n")
    }
}

/// The decoded form of the `Source` field.
///
/// A named shape rather than a bare array of anchors, so the primary is
/// explicit in the stored value instead of being "whatever is first" by
/// convention. A reader upgrading later has to be able to tell which of the
/// two readings a string was written under.
public struct PDFCardSource: Codable, Sendable, Hashable {
    /// Where the app re-opens the card.
    public var primary: PDFSourceAnchor
    /// Every anchor, `primary` included, in the order the user added them.
    public var all: [PDFSourceAnchor]

    public init(primary: PDFSourceAnchor, all: [PDFSourceAnchor]) {
        self.primary = primary
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try container.decode(PDFSourceAnchor.self, forKey: .primary)
        // Tolerate a stored value that carries only `primary`. Reading a
        // half-written park must not fail in a way that loses the primary too.
        all = try container.decodeIfPresent([PDFSourceAnchor].self, forKey: .all) ?? [primary]
    }
}
