public import Foundation

/// A durable pointer back into the exact place in a book a card, highlight,
/// or bookmark came from.
///
/// Why this exists: a page/fraction is not an anchor. It is a *rendering* of a
/// document under a particular font size, column width, and device, so it
/// changes on rotation, on a different device, and after a typography change —
/// while the note still claims to point at a specific sentence. A DOM
/// character index has the opposite problem: it is precise but brittle,
/// because the document is re-extracted and the DOM is rebuilt every launch.
///
/// So an anchor carries both, plus a text quote, and resolution tries them in
/// order of precision:
///
/// 1. `cfi` — a character index within the container's rendered text. Fast and
///    exact, valid only for the extraction it was captured from.
/// 2. `path` — a child-index path from the container to the text node. Survives
///    re-tokenisation, since tokenisation replaces text nodes with spans but
///    keeps element structure.
/// 3. `quote` — the surrounding text with the selection marked. Survives
///    structural edits, which is why it is the fallback of last resort.
///
/// `contextBefore`/`contextAfter` are the ±N characters of surrounding text
/// used for the quote-search disambiguation, matching the W3C Web Annotation
/// "TextQuoteSelector" shape so a future interchange is a straight mapping.
public struct ReaderSourceAnchor: Codable, Sendable, Hashable {
    /// Schema version, so a future migration can tell an old shape apart.
    public var version: Int

    /// Book the anchor points into.
    public var bookID: String
    /// Chapter within the book, as an opaque identifier. EPUB chapter IDs are
    /// derived from spine position rather than being stored, so this is a
    /// hint; resolution verifies it and falls back to a full-book search.
    public var chapterID: Int64?
    /// Href of the chapter document *relative to the book content root* —
    /// never an absolute path, so the anchor survives the library moving
    /// between devices, profiles, and iCloud.
    public var chapterHref: String?

    /// Character offset of the anchor within the container's rendered text.
    public var cfi: Int?
    /// Child-index path from the container element to the anchored text node,
    /// e.g. `[0, 2, 1, 0]`.
    public var path: [Int]?

    /// The anchored text itself, normalised.
    public var quote: String
    /// Text before / after the anchor, used to disambiguate a repeated quote.
    public var contextBefore: String?
    public var contextAfter: String?

    public var createdAt: Date

    public init(
        version: Int = ReaderSourceAnchor.currentVersion,
        bookID: String,
        chapterID: Int64? = nil,
        chapterHref: String? = nil,
        cfi: Int? = nil,
        path: [Int]? = nil,
        quote: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        createdAt: Date = .now
    ) {
        self.version = version
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterHref = chapterHref
        self.cfi = cfi
        self.path = path
        self.quote = quote
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.createdAt = createdAt
    }

    public static let currentVersion = 1

    /// Public initializer used when resolving a decoded payload: the book and
    /// chapter identity are filled in by the reader, which is the only layer
    /// that knows them.
    public init(
        cfi: Int?,
        path: [Int]?,
        quote: String,
        contextBefore: String?,
        contextAfter: String?
    ) {
        self.init(
            bookID: "",
            cfi: cfi,
            path: path,
            quote: quote,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
    }

    /// Decoded from the `anchor` object the injected script posts alongside a
    /// word tap. Fails closed on a missing or malformed payload so an older
    /// build of the script (which sends no anchor) degrades to a nil anchor
    /// rather than a wrong one.
    public init?(scriptPayload: Any?) {
        guard let payload = scriptPayload as? [String: Any] else { return nil }
        guard let quote = payload["quote"] as? String, !quote.isEmpty else { return nil }
        self.init(
            cfi: payload["cfi"] as? Int,
            path: payload["path"] as? [Int],
            quote: quote,
            contextBefore: payload["contextBefore"] as? String,
            contextAfter: payload["contextAfter"] as? String
        )
    }

    /// Text used for the ±context window when the reader captures an anchor.
    /// Long enough to be unique in a paragraph, short enough not to bloat the
    /// note. Matches the Web Annotation recommendation.
    public static let contextCharacterCount = 32

    /// Normalises text for quote comparison: collapses whitespace runs to a
    /// single space and trims, so a re-extraction that reflows a line break
    /// does not defeat the match.
    public static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
