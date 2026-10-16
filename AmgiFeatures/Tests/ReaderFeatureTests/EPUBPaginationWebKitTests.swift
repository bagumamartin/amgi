#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import ReaderFeature

/// Runs the shipped stylesheet and page script in a real web view and checks
/// what is actually on screen for each page.
///
/// Every word of the fixture is numbered (`w0000`, `w0001`, …), so "the page
/// shows the right text" is a checkable fact: page N must show the run of
/// words right after page N-1's, with nothing skipped and nothing repeated,
/// and whatever is painted at a point inside the page must be one of them.
/// The bugs these lock down — a turn that left the text where it was while
/// the counter moved on, a turn back that skipped, a page left between two
/// pages — all broke exactly this.
@MainActor
@Suite("EPUB pagination in WebKit", .serialized)
struct EPUBPaginationWebKitTests {
    /// About thirty phone-sized pages of numbered words in short paragraphs,
    /// with a heading and a figure-like block so the layout is not uniform.
    static let chapter: String = {
        var html = "<html><head><title>t</title></head><body><h1>Chapter</h1>"
        var word = 0
        for paragraph in 0..<180 {
            html += "<p>"
            for _ in 0..<(18 + paragraph % 7) {
                html += String(format: "w%04d ", word)
                word += 1
            }
            html += "</p>"
            if paragraph == 40 { html += "<div style=\"height:120px\"></div>" }
        }
        return html + "</body></html>"
    }()

    @Test("every page shows the words right after the previous page's")
    func pagesAreContiguous() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        let first = try await page.show(0)
        #expect(first.page == 0)
        #expect(first.pageCount > 5)
        var previousLast = try #require(first.lastOffset)
        for index in 1..<first.pageCount {
            let state = try await page.show(index)
            #expect(state.page == index)
            let firstWord = try #require(state.firstOffset, "page \(index) shows no words")
            #expect(firstWord == previousLast + 1, "page \(index) starts at \(firstWord), previous ended at \(previousLast)")
            previousLast = try #require(state.lastOffset)
        }
        #expect(previousLast == (try await page.tokenCount()) - 1, "the last page ends on the last word")
    }

    @Test("what is painted inside the page is one of the page's words")
    func paintedWordsMatchTheState() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        for index in [0, 3, 7, 12] {
            let state = try await page.show(index)
            let painted = try #require(try await page.tokenIndexPainted(atX: 60, y: 120), "nothing painted on page \(index)")
            let range = try #require(state.firstOffset)...(try #require(state.lastOffset))
            #expect(range.contains(painted), "page \(index): painted word \(painted) is outside \(range)")
        }
    }

    @Test("ten pages forward and ten back lands on the same words")
    func roundTrip() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        let start = try await page.show(4)
        for index in 5...14 { _ = try await page.show(index) }
        for index in stride(from: 13, through: 4, by: -1) { _ = try await page.show(index) }
        let back = try await page.state()
        #expect(back.page == 4)
        #expect(back.firstOffset == start.firstOffset)
    }

    @Test("the last page is reachable as -1, and pages clamp inside the chapter")
    func lastPageAndClamping() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        let last = try await page.show(-1)
        #expect(last.page == last.pageCount - 1)
        let beyond = try await page.show(last.pageCount + 10)
        #expect(beyond.page == last.pageCount - 1)
        let before = try await page.show(-5)
        #expect(before.page == last.pageCount - 1, "any negative page means the last page")
    }

    @Test("a re-flow keeps the reader on the same words, not the same page number")
    func relayoutKeepsPlace() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        let before = try await page.show(9)
        let word = try #require(before.firstOffset)
        try await page.run("document.documentElement.style.setProperty('--reader-font-size', '24px')")
        try await page.run("window.__amgiRelayout()")
        let after = try await page.state()
        let range = try #require(after.firstOffset)...(try #require(after.lastOffset))
        #expect(range.contains(word), "word \(word) should still be on screen after the re-flow, page shows \(range)")
        #expect(after.pageCount > before.pageCount, "a larger font lays out to more pages")
    }

    @Test("every page keeps its top and bottom margins")
    func everyPageKeepsItsMargins() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        let count = try await page.show(0).pageCount
        for index in [0, 1, count / 2, count - 1] {
            _ = try await page.show(index)
            // The painted words of this page, top and bottom.
            let extent = try await page.call("""
            var top = Infinity, bottom = -Infinity, w = window.innerWidth;
            document.querySelectorAll('.amgi-tok').forEach(function (t) {
              var r = t.getBoundingClientRect();
              if (r.width > 0 && r.left >= 0 && r.right <= w) {
                top = Math.min(top, r.top); bottom = Math.max(bottom, r.bottom);
              }
            });
            return [top, bottom];
            """) as? [NSNumber]
            let top = try #require(extent?.first?.doubleValue)
            let bottom = try #require(extent?.last?.doubleValue)
            #expect(top >= 100 - 1, "page \(index): text starts at \(top), above the 100pt inset")
            #expect(bottom <= 760 - 90 + 1, "page \(index): text ends at \(bottom), below the 90pt inset")
        }
    }

    @Test("nothing scrolls: the document stays at its origin")
    func documentNeverScrolls() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        _ = try await page.show(6)
        try await page.run("document.documentElement.scrollLeft = 500")
        try await page.run("new Promise(function (r) { setTimeout(r, 50); })")
        let scrolled = try await page.number("document.documentElement.scrollLeft")
        #expect(scrolled == 0)
        #expect(try await page.state().page == 6)
    }

    @Test("resolving an anchor shows the page its words are on")
    func anchorShowsItsPage() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        try await page.run("window.__amgiResolveAnchor({quote: 'w2500 w2501 w2502'})")
        let state = try await page.state()
        let range = try #require(state.firstOffset)...(try #require(state.lastOffset))
        let target = try await page.number("""
        Array.prototype.findIndex.call(document.querySelectorAll('.amgi-tok'),
          function (t) { return t.textContent === 'w2500'; })
        """)
        #expect(range.contains(Int(target)), "w2500 (token \(Int(target))) should be on the page shown, which has \(range)")
    }

    @Test("the synchronous Mac calls move the page too")
    func macCallsMoveThePage() async throws {
        let page = try await PaginatedPage.load(Self.chapter)
        try await page.run("window.__amgiScrollToPage(5)")
        #expect(try await page.state().page == 5)
        try await page.run("window.__amgiScrollToFraction(1)")
        let state = try await page.state()
        #expect(state.page == state.pageCount - 1)
    }
}

/// A phone-sized web view with the reader's stylesheet and script applied the
/// way the app applies them.
@MainActor
private final class PaginatedPage: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loaded: CheckedContinuation<Void, any Error>?

    private override init() {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        // In a window, so WebKit lays the page out and paints it as it would
        // on a device.
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        super.init()
        webView.navigationDelegate = self
    }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    static func load(_ html: String) async throws -> PaginatedPage {
        let script = try String(contentsOf: EPUBReaderInjectionScriptTests.scriptPath, encoding: .utf8)
        let css = try String(contentsOf: ReaderReaderStylesheetTests.cssPath, encoding: .utf8)
        let page = PaginatedPage()
        try await withCheckedThrowingContinuation { continuation in
            page.loaded = continuation
            page.webView.loadHTMLString(html, baseURL: nil)
        }
        let cssLiteral = String(data: try JSONSerialization.data(withJSONObject: [css]), encoding: .utf8)!
        try await page.run("""
        (function () {
          var s = document.createElement('style');
          s.textContent = \(cssLiteral)[0];
          document.head.appendChild(s);
          var r = document.documentElement.style;
          r.setProperty('--reader-font-size', '17px');
          r.setProperty('--reader-page-margin', '24px');
          r.setProperty('--reader-inset-top', '100px');
          r.setProperty('--reader-inset-bottom', '90px');
        })()
        """)
        try await page.run("(function () {\n\(script)\n})()")
        // Let the script's own boot relayouts run.
        try await page.run("new Promise(function (r) { setTimeout(r, 350); })")
        try await page.run("window.__amgiRelayout()")
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

    func show(_ page: Int) async throws -> EPUBPageState {
        try decodeState(try await call("return await window.__amgiShowPage(\(page));"))
    }

    func state() async throws -> EPUBPageState {
        try decodeState(try await call("return window.__amgiPageState();"))
    }

    func tokenCount() async throws -> Int {
        Int(try await number("document.querySelectorAll('.amgi-tok').length"))
    }

    /// The index of a word token actually painted near a point inside the
    /// page, probing a small grid so a gap between words is not a miss.
    func tokenIndexPainted(atX x: Double, y: Double) async throws -> Int? {
        let value = try await call("""
        var all = document.querySelectorAll('.amgi-tok');
        for (var dy = 0; dy < 80; dy += 8) {
          for (var dx = 0; dx < 120; dx += 6) {
            var el = document.elementFromPoint(\(x) + dx, \(y) + dy);
            var tok = el && el.closest ? el.closest('.amgi-tok') : null;
            if (tok) { return Array.prototype.indexOf.call(all, tok); }
          }
        }
        return -1;
        """)
        let index = (value as? NSNumber)?.intValue ?? -1
        return index >= 0 ? index : nil
    }

    func number(_ expression: String) async throws -> Double {
        (try await call("return (\(expression));") as? NSNumber)?.doubleValue ?? .nan
    }

    func run(_ statement: String) async throws {
        _ = try await call("return await (\(statement));")
    }

    func call(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
    }

    private func decodeState(_ value: Any?) throws -> EPUBPageState {
        try #require(EPUBPageState(scriptResult: value), "the page returned no state: \(String(describing: value))")
    }
}
#endif
