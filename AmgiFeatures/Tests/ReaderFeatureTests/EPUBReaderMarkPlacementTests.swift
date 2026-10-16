#if os(macOS)
import Foundation
import Testing
import WebKit

/// Runs the shipped reader script in a real web view and checks that a mark
/// lands on the words it was made from.
///
/// Anchors, marks, and anchor resolution once each counted offsets from a
/// different origin (the paragraph, the word tokens, the raw text), so every
/// mark was painted near the start of the chapter. A string check on the
/// script cannot catch that; only running it can.
@MainActor
@Suite("EPUB reader mark placement")
struct EPUBReaderMarkPlacementTests {
    static let chapter = """
    <html><head><style>#furniture{}</style></head><body>
    <h1>Embedded Systems</h1>
    <p>Peter Marwedel</p>
    <p>TU Dortmund, Dortmund, Germany</p>
    <p>While this book was written, the so-called smart systems grew.</p>
    </body></html>
    """

    @Test("an anchor taken from a quote marks exactly that quote")
    func anchorForQuoteMarksItsOwnWords() async throws {
        let page = try await ReaderPage.load(Self.chapter)
        let anchor = try await page.object("window.__amgiAnchorForQuote({quote: 'Germany'})")
        let cfi = try #require(anchor["cfi"] as? Int)
        let marked = try await page.mark(start: cfi, text: "Germany")
        #expect(marked == ["Germany"])
    }

    @Test("a paragraph-relative offset from an older anchor is re-found by its text")
    func legacyOffsetIsCorrected() async throws {
        let page = try await ReaderPage.load(Self.chapter)
        // "called" sits 36 characters into its own paragraph, which is where
        // anchors used to count from; chapter-wide, 36 is two paragraphs up.
        let marked = try await page.mark(start: 36, text: "called")
        #expect(marked == ["called"])
    }

    @Test("a repeated word resolves to the occurrence nearest the offset")
    func repeatedWordUsesNearestOccurrence() async throws {
        let page = try await ReaderPage.load(Self.chapter)
        let text = try await page.string("document.body.textContent")
        let second = try #require(text.range(of: "Dortmund", options: .backwards))
        let offset = text.distance(from: text.startIndex, to: second.lowerBound)
        // Off by two, as a drifted offset would be.
        _ = try await page.mark(start: offset + 2, text: "Dortmund")
        let index = try await page.string("""
        String(Array.prototype.indexOf.call(
          document.querySelectorAll('.amgi-tok'),
          document.querySelector('[data-amgi-mark]')))
        """)
        let firstIndex = try await page.string("""
        String(Array.prototype.findIndex.call(
          document.querySelectorAll('.amgi-tok'),
          function (t) { return t.textContent === 'Dortmund'; }))
        """)
        #expect(Int(index)! == Int(firstIndex)! + 1)
    }

    @Test("an anchor for a multi-word selection marks every selected word")
    func selectionAnchorMarksTheSelection() async throws {
        let page = try await ReaderPage.load(Self.chapter)
        // Select "smart systems" through the DOM, then ask the anchor builder
        // the selection reporter uses for its offset.
        let cfi = try await page.string("""
        (function () {
          var tokens = Array.prototype.filter.call(
            document.querySelectorAll('.amgi-tok'),
            function (t) { return t.textContent === 'smart' || t.textContent === 'systems'; });
          var range = document.createRange();
          range.setStart(tokens[0].firstChild, 0);
          range.setEnd(tokens[tokens.length - 1].firstChild, 7);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          var found = window.__amgiAnchorForQuote({quote: sel.toString()});
          return String(found.cfi);
        })()
        """)
        let marked = try await page.mark(start: Int(cfi)!, text: "smart systems")
        #expect(marked == ["smart", "systems"])
    }

    @Test("resolving an older anchor goes by its quote, not its stale offset")
    func resolveCorrectsLegacyOffset() async throws {
        let page = try await ReaderPage.load(Self.chapter)
        let result = try await page.object(
            "window.__amgiResolveAnchor({cfi: 3, quote: 'TU Dortmund, Dortmund, Germany'})"
        )
        #expect(result["strategy"] as? String == "quote")
    }
}

/// One loaded chapter with the reader script injected the way the app does it.
@MainActor
private final class ReaderPage: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, any Error>?

    private override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        webView.navigationDelegate = self
    }

    static func load(_ html: String) async throws -> ReaderPage {
        let script = try String(contentsOf: EPUBReaderInjectionScriptTests.scriptPath, encoding: .utf8)
        let page = ReaderPage()
        try await withCheckedThrowingContinuation { continuation in
            page.loaded = continuation
            page.webView.loadHTMLString(html, baseURL: nil)
        }
        // Run once the document has loaded, which is when the app's
        // document-end user script runs it too.
        _ = try await page.evaluate("(function () {\n\(script)\n})(), 0")
        return page
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func string(_ script: String) async throws -> String {
        try decode(try await evaluate(script)) as? String ?? ""
    }

    func object(_ script: String) async throws -> [String: Any] {
        try decode(try await evaluate(script)) as? [String: Any] ?? [:]
    }

    private func decode(_ json: String) throws -> Any? {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
    }

    /// Applies one card-draft mark and returns the text of every marked token.
    func mark(start: Int, text: String) async throws -> [String] {
        let payload: [String: Any] = [
            "id": "m", "kind": "cardDraft", "start": start, "end": start + text.count, "text": text,
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: [payload]), encoding: .utf8)!
        _ = try await evaluate("window.__amgiApplyMarks(\(json))")
        let joined = try await string("""
        Array.prototype.map.call(
          document.querySelectorAll('[data-amgi-mark]'),
          function (t) { return t.textContent; }).join('|')
        """)
        return joined.isEmpty ? [] : joined.components(separatedBy: "|")
    }

    /// Evaluates `script` and returns its result as JSON text, which crosses
    /// the continuation as a plain (Sendable) string.
    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("JSON.stringify((\(script)) ?? null)") { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String ?? "null")
                }
            }
        }
    }
}
#endif
