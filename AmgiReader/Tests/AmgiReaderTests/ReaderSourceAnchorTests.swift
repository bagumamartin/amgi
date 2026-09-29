import Foundation
import Testing
@testable import AmgiReader

/// A source anchor is only as good as its weakest handle: a note that points
/// at the wrong sentence is worse than one that points nowhere. These cover
/// the decode path from the injected script and the normalisation that decides
/// whether a re-extraction can still find the same words.
@Suite("Reader source anchor")
struct ReaderSourceAnchorTests {
    // MARK: - Script payload decoding

    @Test("a full script payload decodes into every handle")
    func decodesFullPayload() throws {
        let payload: [String: Any] = [
            "cfi": 412,
            "path": [0, 2, 1, 0],
            "quote": "the anchored sentence.",
            "contextBefore": "some earlier text",
            "contextAfter": "and some later text",
        ]
        let anchor = try #require(ReaderSourceAnchor(scriptPayload: payload))
        #expect(anchor.cfi == 412)
        #expect(anchor.path == [0, 2, 1, 0])
        #expect(anchor.quote == "the anchored sentence.")
        #expect(anchor.contextBefore == "some earlier text")
        #expect(anchor.contextAfter == "and some later text")
    }

    @Test("a missing or malformed payload yields no anchor rather than a wrong one")
    func failsClosedOnBadPayload() {
        // An older injected script sends no anchor at all; a book script could
        // send anything. Both must degrade to nil, never to a partial anchor
        // that would resolve to the wrong text.
        #expect(ReaderSourceAnchor(scriptPayload: nil) == nil)
        #expect(ReaderSourceAnchor(scriptPayload: "not a dictionary") == nil)
        #expect(ReaderSourceAnchor(scriptPayload: ["cfi": 12]) == nil)
        #expect(ReaderSourceAnchor(scriptPayload: ["quote": ""]) == nil)
    }

    @Test("optional handles may be absent without invalidating the anchor")
    func optionalHandlesMayBeMissing() throws {
        // The quote alone is a usable fallback, so an anchor with no offset and
        // no path is still better than none.
        let anchor = try #require(
            ReaderSourceAnchor(scriptPayload: ["quote": "just the quote"])
        )
        #expect(anchor.cfi == nil)
        #expect(anchor.path == nil)
        #expect(anchor.quote == "just the quote")
    }

    @Test("a decoded anchor carries a version so a later migration can tell it apart")
    func decodedAnchorIsVersioned() throws {
        let anchor = try #require(
            ReaderSourceAnchor(scriptPayload: ["quote": "q"])
        )
        #expect(anchor.version == ReaderSourceAnchor.currentVersion)
    }

    // MARK: - Normalisation

    @Test("whitespace is folded so a rewrapped line still matches")
    func normalisationFoldsWhitespace() {
        let a = ReaderSourceAnchor.normalize("the quick\n   brown\tfox")
        let b = ReaderSourceAnchor.normalize("the quick brown fox")
        #expect(a == b)
        #expect(a == "the quick brown fox")
    }

    @Test("normalisation trims but preserves internal punctuation and case")
    func normalisationTrimsOnly() {
        #expect(ReaderSourceAnchor.normalize("  Hello, world.  ") == "Hello, world.")
    }

    @Test("normalisation is idempotent")
    func normalisationIsIdempotent() {
        let once = ReaderSourceAnchor.normalize("  a\n\n  b  ")
        #expect(ReaderSourceAnchor.normalize(once) == once)
    }

    // MARK: - Round trip

    @Test("an anchor survives a JSON round trip unchanged")
    func codableRoundTrip() throws {
        let original = ReaderSourceAnchor(
            bookID: "epub-abc",
            chapterID: 7,
            chapterHref: "OEBPS/Text/ch3.xhtml",
            cfi: 1_024,
            path: [1, 0, 3],
            quote: "a quoted passage",
            contextBefore: "before",
            contextAfter: "after",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReaderSourceAnchor.self, from: data)
        #expect(decoded == original)
    }

    @Test("the context window is wide enough to disambiguate but bounded")
    func contextWindowIsSane() {
        #expect(ReaderSourceAnchor.contextCharacterCount >= 16)
        #expect(ReaderSourceAnchor.contextCharacterCount <= 128)
    }
}
