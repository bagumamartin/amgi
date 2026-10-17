import AmgiReader
import AmgiTheme
import AmgiAppCore
import OSLog
import Foundation
#if os(iOS)
import UIKit
#endif
import WebKit

/// Per-chapter content payload handed to the page controller. The host
/// rebuilds this whenever the user crosses a chapter boundary.
struct EPUBChapterContent: Equatable {
    let chapterID: Int64
    /// On-disk URL of the chapter XHTML inside the book's extracted
    /// directory. The WebView is granted read-access to `readAccessURL`
    /// (the book's extracted root) so referenced CSS/images resolve.
    let contentURL: URL
    /// Root the WebView gets `loadFileURL` read-access to.
    let readAccessURL: URL
    /// Identity needed to build a durable source anchor. The injected script
    /// runs inside the page and cannot know these, so the page controller
    /// stamps them onto the anchor the script produced.
    let bookID: String
    /// Href of the chapter document relative to the book content root. Stored
    /// instead of an absolute path so an anchor survives the library moving
    /// between devices, profiles, and iCloud.
    let chapterHref: String?
}

#if os(iOS)
#endif

/// CSS tokens passed from SwiftUI prefs into the injected stylesheet.
/// Reused as `--reader-*` custom properties in `EPUBReaderStyles.css`.
/// New typography settings (`fontFamilyCSS`, `pageMarginPx`, `textAlign`,
/// `insetTopPx`) come from `ReaderTypographyPreferences`; the
/// legacy fields are kept for the per-book settings panel.
struct EPUBReaderStyleTokens: Equatable {
    var foreground: String = "#1f2a26"
    var background: String = "#faf7f2"
    var theme: String = "original"
    var fontSizePx: Int = 17
    var lineHeight: Double = 1.55
    var paddingPx: Int = 22
    var verticalMode: Bool = false
    /// Empty means "use the book's own font", which is what Apple Books does
    /// and what a well-typeset book expects. A non-empty stack overrides it.
    var fontFamilyCSS: String = ""
    var pageMarginPx: Int = 24
    var textAlign: String = "justify"
    /// Press tint for a token. There is deliberately no persistent
    /// underline: a decoration on every word makes the page unreadable and
    /// reads as broken rendering rather than as an affordance.
    var pressTintCSS: String = "rgba(120, 120, 120, 0.22)"
    /// Space reserved at the top of every page for the floating chrome.
    var insetTopPx: Int = 0
    /// Space reserved at the bottom of every page for the chrome, so the last
    /// line of a page is never hidden behind the page counter.
    var insetBottomPx: Int = 0
    /// Centre line of the title row, from the top of the page, and of the
    /// folio row, from the bottom. The running head and page number sit on
    /// these lines, which are the same lines the reader's chrome uses — so the
    /// chrome replaces them in place rather than stacking over the text.
    var headCenterPx: Int = 40
    var footCenterPx: Int = 32
    /// Number of logical pages visible in one physical WebKit viewport.
    /// The bundled CSS halves its column width for a spread, while native
    /// paging remains based on the full viewport.
    var pageColumns: Int = 1
}

/// Bundled reader web resources shared by both platform hosts.
enum EPUBReaderBundledResources {
    /// CSP installer, registered at document start so the book's own markup
    /// is parsed under it. Must be added before every other user script.
    static var contentSecurityPolicyScript: String {
        EPUBNavigationPolicy.contentSecurityPolicyScript
    }

    static func css() -> String? {
        let url = Bundle.main.url(forResource: "EPUBReaderStyles", withExtension: "css", subdirectory: "EPUBReader")
            ?? Bundle.main.url(forResource: "EPUBReaderStyles", withExtension: "css")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func js() -> String? {
        let url = Bundle.main.url(forResource: "EPUBReaderInjection", withExtension: "js", subdirectory: "EPUBReader")
            ?? Bundle.main.url(forResource: "EPUBReaderInjection", withExtension: "js")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The bundled tap handler intentionally treats every token as a lookup.
    /// Guard live text selections before it so the click that dismisses a
    /// selection cannot also open lookup or turn the page.
    static func interactionJS() -> String? {
        guard let source = js() else { return nil }
        return """
        (function() {
          document.addEventListener('click', function(event) {
            var selection = window.getSelection();
            if (selection && !selection.isCollapsed && selection.toString().trim().length > 0) {
              event.stopImmediatePropagation();
            }
          }, true);
        })();
        \(source)
        """
    }

    /// Empty-page taps are routed through the same document listener as token
    /// taps. The mutually-exclusive early return guarantees one click can
    /// produce either `wordTap` or `emptyTap`, never both.
    static let emptyTapScript = """
    (function() {
      document.addEventListener('click', function(event) {
        var selection = window.getSelection();
        if (selection && !selection.isCollapsed && selection.toString().trim().length > 0) return;

        var target = event.target;
        // A tap on a capture — a card's or a waiting draft's passage, or a
        // captured area's box — opens that capture's menu instead of toggling
        // the chrome. Boxes let touches through, so they are found by where
        // the tap was, not by what it hit.
        var mark = window.__amgiMarkAt ? window.__amgiMarkAt(event.clientX, event.clientY) : null;
        if (!(mark && (mark.kind === 'card' || mark.kind === 'cardDraft'))) {
          var carded = target && target.closest
            ? target.closest('.amgi-tok[data-amgi-mark="cardDraft"], .amgi-tok[data-amgi-mark="card"]')
            : null;
          mark = carded
            ? { id: carded.getAttribute('data-amgi-mark-id'), kind: carded.getAttribute('data-amgi-mark') }
            : null;
        }
        if (mark && mark.id) {
          try {
            window.webkit.messageHandlers.markTap.postMessage({
              id: mark.id,
              kind: mark.kind,
              x: event.clientX || 0,
              y: event.clientY || 0
            });
          } catch (e) { /* host detached */ }
          return;
        }
        if (target && target.closest && target.closest('.amgi-tok, a, button, input, select, textarea, [role="button"]')) return;

        var width = window.innerWidth || document.documentElement.clientWidth || 1;
        var relativeX = Math.max(0, Math.min(1, (event.clientX || 0) / width));
        try {
          window.webkit.messageHandlers.emptyTap.postMessage(relativeX);
        } catch (e) { /* host detached */ }
      }, true);
    })();
    """

    static func injectStyleSnippet(css: String) -> String {
        let escaped = css.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
        // The book may ship <link rel="stylesheet"> nodes that load
        // asynchronously and would otherwise win the cascade against
        // our injected variables/overrides. We append our <style> as
        // the LAST child of <head> (so it wins on document order at
        // equal specificity), and re-append it after `window.load`
        // and on a one-tick microtask so any late-arriving book
        // stylesheets can't override us.
        return """
        (function() {
          function place() {
            var existing = document.querySelector('style[data-amgi="reader"]');
            var s = existing || document.createElement('style');
            if (!existing) {
              s.setAttribute('data-amgi', 'reader');
              s.textContent = `\(escaped)`;
            }
            var head = document.head || document.documentElement;
            // Re-append moves the node to the end of head's child list.
            head.appendChild(s);
          }
          place();
          setTimeout(place, 0);
          if (document.readyState === 'complete') {
            setTimeout(place, 0);
          } else {
            window.addEventListener('load', function() { setTimeout(place, 0); }, { once: true });
          }
        })();
        """
    }
}

#if os(iOS)

/// Callbacks emitted by a chapter page back up to the host coordinator.
@MainActor
protocol EPUBChapterPageControllerDelegate: AnyObject {
    func epubChapter(_ controller: EPUBChapterPageController, didReportPageInfoIndex pageIndex: Int, pageCount: Int)
    func epubChapter(_ controller: EPUBChapterPageController, didReportProgressFraction fraction: Double, pageIndex: Int)
    /// A long press produced a selection. `token` is the word under the
    /// selection start (what a dictionary should be asked about); `text` is
    /// the full selected range.
    func epubChapter(
        _ controller: EPUBChapterPageController,
        didSelectText text: String,
        token: String,
        sentence: String,
        anchor: ReaderSourceAnchor?
    )
    func epubChapter(_ controller: EPUBChapterPageController, didSelectTextForNote text: String)
    func epubChapterDidTapEmptySpace(_ controller: EPUBChapterPageController, atRelativeX relativeX: CGFloat)
}

/// Hosts one chapter's WKWebView, configured for native UIScrollView
/// paging over the CSS multi-column layout. Reports page info, progress,
/// and word taps via `EPUBChapterPageControllerDelegate`.
@MainActor
final class EPUBChapterPageController: UIViewController, UIGestureRecognizerDelegate {
    let chapterIndex: Int
    let content: EPUBChapterContent
    var styleTokens: EPUBReaderStyleTokens
    /// 0..1 fraction to scroll to once a freshly-loaded chapter reports
    /// its page count. Consumed and cleared inside the bridge.
    private(set) var pendingRestoreFraction: Double?
    /// Absolute column target for a page controller supplied by UIKit's
    /// interactive curl. `-1` requests the final page in the chapter.
    private(set) var pendingPageIndex: Int?
    let isPageCurlManaged: Bool
    private var pendingAnchor: ReaderSourceAnchor?

    weak var pageDelegate: (any EPUBChapterPageControllerDelegate)?

    fileprivate var webView: WKWebView!
    private var bridge: ScriptBridge!
    /// The page's last reported selection. Only shapes the menu when it is
    /// built; an item re-reads the live selection when it is chosen, because
    /// the page reports on a debounce and can trail the handles.
    private var latestSelection: ReaderSelectionPayload?
    /// Last viewport size pushed to CSS. Used to detect real layout
    /// changes (rotation, safe-area updates) so we don't trigger a
    /// relayout for every spurious `viewDidLayoutSubviews` tick.
    private var lastPushedPageSize: CGSize = .zero
    /// Whether the WebView has finished its initial navigation. Until
    /// then `evaluateJavaScript` calls targeting `__amgiRelayout` are
    /// silently dropped — we let `webView(_:didFinish:)` push the first
    /// layout instead.
    private var didFinishInitialLoad: Bool = false

    init(
        chapterIndex: Int,
        content: EPUBChapterContent,
        styleTokens: EPUBReaderStyleTokens,
        pendingRestoreFraction: Double?,
        pendingPageIndex: Int? = nil,
        isPageCurlManaged: Bool = false
    ) {
        self.chapterIndex = chapterIndex
        self.content = content
        self.styleTokens = styleTokens
        self.pendingRestoreFraction = pendingRestoreFraction
        self.pendingPageIndex = pendingPageIndex
        self.isPageCurlManaged = isPageCurlManaged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: UIGestureRecognizerDelegate

    /// Our swipe and WebKit's own pans are allowed to run together; which one
    /// handles the touch is settled by the direction test in `handleSwipe`.
    /// Blocking co-recognition here would break text selection, which the
    /// platform handles with its own long-press pan.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// A touch on the selection belongs to WebKit — lifting it to drag onto a
    /// docked card, or moving a handle — so the swipe never sees it. Anywhere
    /// else on the page a swipe still turns it, selection or not.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(gestureRecognizer === swipeRecogniser && touchIsOnSelection(touch))
    }

    /// Whether a touch lands on the live selection or close enough to grab
    /// one of its handles.
    ///
    /// Read synchronously from a gesture callback, so it works from the rects
    /// the page last reported rather than asking the page. With a selection
    /// but no rects yet (the report is debounced), the whole page counts: a
    /// swipe that waits for one report is better than a drag that is eaten.
    func touchIsOnSelection(_ touch: UITouch) -> Bool {
        guard hasLiveSelection else { return false }
        guard !selectionRects.isEmpty else { return true }
        let point = touch.location(in: webView)
        return selectionRects.contains { $0.insetBy(dx: -Self.selectionTouchSlop, dy: -Self.selectionTouchSlop).contains(point) }
    }

    /// Room around the selection that still counts as on it — the drag
    /// handles sit just outside the selected text.
    private static let selectionTouchSlop: CGFloat = 24

    /// The live selection's line boxes, in the web view's coordinates.
    private var selectionRects: [CGRect] = []

    fileprivate func noteSelectionRects(_ value: Any?) {
        selectionRects = ((value as? [[Double]]) ?? []).compactMap { box in
            box.count == 4 ? CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) : nil
        }
    }
    override func loadView() {
        let config = WKWebViewConfiguration()
        // On iOS `dataDetectorTypes` lives on the configuration, not the view.
        config.dataDetectorTypes = []
        let userContent = WKUserContentController()

        // First script: the CSP has to be in place before the book parses.
        userContent.addUserScript(WKUserScript(
            source: EPUBReaderBundledResources.contentSecurityPolicyScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        if let css = Self.bundledCSS() {
            let cssScript = WKUserScript(
                source: Self.injectStyleSnippet(css: css),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            userContent.addUserScript(cssScript)
        }
        if let js = Self.interactionJS() {
            let jsScript = WKUserScript(
                source: js,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            userContent.addUserScript(jsScript)
        }
        userContent.addUserScript(WKUserScript(
            source: Self.emptyTapScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        bridge = ScriptBridge(owner: self)
        userContent.add(bridge, name: "pageInfo")
        userContent.add(bridge, name: "progress")
        userContent.add(bridge, name: "wordSelection")
        userContent.add(bridge, name: "emptyTap")
        userContent.add(bridge, name: "markTap")

        config.userContentController = userContent
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = ReaderWebView(frame: .zero, configuration: config)
        // Paging is driven by the host, not by UIScrollView.
        //
        // `isPagingEnabled` was the reason the selected page transition only
        // half worked: the scroll view snapped between columns on its own, so
        // every intra-chapter turn was a hard slide no matter what the user
        // had chosen, and it could not be curled, faded, or eased. Letting the
        // host own the offset means one pipeline handles every turn — inside
        // a chapter and across a boundary — and the chosen effect applies to
        // all of them.
        // The web view's scroll view never moves. Pages are a transform
        // inside the document (stylesheet rev 4); any offset here would show
        // a different page from the one the document reports — which is how
        // the reader came to say "page 1" over page 3's text.
        webView.scrollView.isPagingEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // The web view already exposes the book's text as its accessibility
        // tree. Leaving the paging scroller exposed too makes VoiceOver treat
        // the snap scroll view as a page list on top of it.
        webView.scrollView.isAccessibilityElement = false
        webView.scrollView.delegate = bridge
        webView.navigationDelegate = bridge
        webView.isOpaque = false
        webView.backgroundColor = .clear

        self.webView = webView
        // In a plain container, so the page turner can lay the live page under
        // a picture of it and move it between page cards.
        let container = UIView()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        self.view = container
        if !isPageCurlManaged { installSwipeRecogniser() }
        // Long press is WebKit's own selection gesture, and WebKit's own menu
        // carries the Anki actions — see `ReaderSystemSelectionMenu`.
        webView.selectionMenuElements = { [weak self] in
            self?.selectionMenuElements() ?? []
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyHostBackgroundColor()
        webView.loadFileURL(content.contentURL, allowingReadAccessTo: content.readAccessURL)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pushPageSizeIfChanged()
    }

    /// Push the WKWebView's current viewport size into CSS as
    /// `--page-width` / `--page-height`, then call `__amgiRelayout` to
    /// reflow the column container and re-snap to the saved page index.
    /// Skips pushes when the size hasn't changed or before the first
    /// navigation completes (the JS hook isn't wired yet).
    fileprivate func pushPageSizeIfChanged(force: Bool = false) {
        guard didFinishInitialLoad else { return }
        let size = webView.scrollView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if !force, size == lastPushedPageSize { return }

        lastPushedPageSize = size
        // The page re-measures and keeps the reader on the same words; its
        // report that follows says where that is.
        ReaderTelemetry.log("relayout", ["page": telemetryTag, "width": Int(size.width)])
        webView.evaluateJavaScript("window.__amgiRelayout && window.__amgiRelayout();", completionHandler: nil)
    }

    fileprivate func applyHostBackgroundColor() {
        let cgColor = UIColor(amgiHex: styleTokens.background) ?? .systemBackground
        webView.backgroundColor = cgColor
        webView.scrollView.backgroundColor = cgColor
        view.backgroundColor = cgColor
    }

    /// Update style tokens on an already-loaded chapter (e.g. user
    /// changed font size while in the same chapter).
    func update(styleTokens: EPUBReaderStyleTokens) {
        self.styleTokens = styleTokens
        applyStyleTokens()
    }

    /// The running head text: the book title, as a printed running head.
    var runningHead: String = ""

    /// Whether the reader's chrome is up. The page's running head and number
    /// step aside while it is, because the chrome shows them on the same lines.
    var chromeVisible = false {
        didSet {
            guard oldValue != chromeVisible, didFinishInitialLoad else { return }
            applyChromeVisibility()
        }
    }

    fileprivate func applyChromeVisibility() {
        webView.evaluateJavaScript(
            "window.__amgiSetChromeVisible && window.__amgiSetChromeVisible(\(chromeVisible));",
            completionHandler: nil
        )
    }

    /// Prints the current page number onto the page.
    func refreshPageFurniture(page: Int? = nil, total: Int? = nil) {
        applyPageFurniture(
            page: page ?? currentPageIndex + 1,
            runningHead: runningHead,
            total: total
        )
    }

    /// Resolve a stored text location after this chapter has finished laying
    /// out. The DOM range owns the exact location; page numbers are only a
    /// visual estimate and do not survive a font-size or rotation change.
    func scroll(to anchor: ReaderSourceAnchor) {
        guard anchor.chapterID == content.chapterID else { return }
        guard didFinishInitialLoad else {
            pendingAnchor = anchor
            return
        }
        guard let data = try? JSONEncoder().encode(anchor),
              let json = String(data: data, encoding: .utf8) else { return }
        ReaderTelemetry.log("anchor.resolve", ["chapter": chapterIndex, "cfi": anchor.cfi ?? -1, "quote": String(anchor.quote.prefix(30))])
        webView.evaluateJavaScript(
            "window.__amgiResolveAnchor && window.__amgiResolveAnchor(\(json));",
            completionHandler: nil
        )
    }

    fileprivate func markInitialLoadFinished() {
        didFinishInitialLoad = true
    }

    /// Programmatic page move used by the host. `animated: false` is used by
    /// the transitions that draw their own animation, so the offset must not
    /// animate as well or the two fight.
    func paginate(direction: PageDirection, animated: Bool = true) {
        let next = currentPageIndex + (direction == .forward ? 1 : -1)
        setPage(next, animated: animated)
    }

    enum PageDirection: Equatable {
        case forward, backward
    }

    /// The page shown and the number of pages, as the page itself last
    /// reported them. Pages are a transform inside the document (rev 4 of the
    /// stylesheet), so nothing on the UIKit side — no scroll offset — knows or
    /// decides which page is showing. These are only ever written from the
    /// page's own reports.
    private(set) var currentPageIndex = 0
    private(set) var pageCount = 1

    /// Records what the page reported. Called for every `pageInfo` message
    /// and every `showPage` result.
    fileprivate func noteReported(page: Int, count: Int) {
        pageCount = max(1, count)
        currentPageIndex = min(max(0, page), pageCount - 1)
    }

    /// Asks the page to show `index` (clamped to the chapter) without waiting
    /// for it to paint. Returns the page asked for; the page's report that
    /// follows is the truth.
    @discardableResult
    func setPage(_ index: Int, animated: Bool = false) -> Int {
        let clamped = min(max(index, 0), max(0, pageCount - 1))
        currentPageIndex = clamped
        webView.evaluateJavaScript("window.__amgiScrollToPage && window.__amgiScrollToPage(\(clamped));", completionHandler: nil)
        return clamped
    }

    /// A page laid out only to count its pages for the book-wide total. It is
    /// never shown and takes no part in reading.
    var isMeasurementOnly = false

    /// A short name for this page in telemetry: chapter, page, and whether it
    /// is a measuring page.
    var telemetryTag: String {
        "c\(chapterIndex)p\(currentPageIndex)\(isMeasurementOnly ? "m" : "")"
    }

    // MARK: - Rendering pages as pictures
    //
    // UIKit's page curl draws the pages it turns by rendering their layers,
    // and a WKWebView's text lives in a separate process that layer rendering
    // cannot see — the curling sheet came out blank. So the page turner turns
    // pictures of pages, and a chapter controller used as a *renderer* draws
    // them: it stays loaded off screen, moves to the page asked for, and takes
    // WebKit's own snapshot. Apple Books turns pictures of its pages too.

    /// A picture of one page of this chapter, with the state the page
    /// reported when it was taken — so a picture can be checked against the
    /// live page before it is trusted. Nil when the chapter has not loaded or
    /// did not reach the page.
    func renderPicture(ofPage page: Int) async -> (image: UIImage, state: EPUBPageState)? {
        guard webView.window != nil, webView.bounds.width > 1, webView.bounds.height > 1,
              let state = await showPage(page), page < 0 || state.page == page else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: UIImage? = await withCheckedContinuation { done in
            webView.takeSnapshot(with: config) { image, _ in done.resume(returning: image) }
        }
        return image.map { ($0, state) }
    }

    /// An area of the page as it is on screen, for a card: WebKit's own
    /// snapshot of the box, and an anchor to the element it covered. `rect`
    /// is in this page's coordinates.
    func captureRegion(_ rect: CGRect) async -> ReaderRegionCapture? {
        let box = rect.intersection(webView.bounds)
        guard didFinishInitialLoad, box.width >= 4, box.height >= 4,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = box
        config.afterScreenUpdates = false
        let image: UIImage? = await withCheckedContinuation { done in
            webView.takeSnapshot(with: config) { image, _ in done.resume(returning: image) }
        }
        guard let png = image?.pngData() else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.__amgiRegionAnchor ? window.__amgiRegionAnchor(x, y, w, h) : null;",
            arguments: ["x": box.minX, "y": box.minY, "w": box.width, "h": box.height],
            contentWorld: .page
        )
        let payload = result as? [String: Any]
        let anchor = ReaderSourceAnchor(
            bookID: content.bookID,
            chapterID: content.chapterID,
            chapterHref: content.chapterHref,
            cfi: payload?["cfi"] as? Int,
            path: payload?["path"] as? [Int],
            quote: (payload?["quote"] as? String) ?? ""
        )
        // On an EPUB page the box is kept relative to the block that holds
        // it (the anchor's `path`), so its mark lands exactly where it was
        // drawn and follows that block through a reflow. Without such a
        // block, relative to the page.
        let size = webView.bounds.size
        let page = (payload?["pageIndex"] as? Int) ?? currentPageIndex
        let held = payload?["box"] as? [String: Any]
        let region: ReaderPageRegion
        if let held, let x = held["x"] as? Double, let y = held["y"] as? Double,
           let w = held["width"] as? Double, let h = held["height"] as? Double {
            region = ReaderPageRegion(page: page, x: x, y: y, width: w, height: h)
        } else {
            region = ReaderPageRegion(
                page: page,
                x: box.minX / size.width,
                y: box.minY / size.height,
                width: box.width / size.width,
                height: box.height / size.height
            )
        }
        return ReaderRegionCapture(image: png, anchor: anchor, region: region)
    }

    /// Shows a page and returns once the page has painted it, with what is
    /// actually on screen: the page, the count, and the first and last words.
    /// `-1` is the last page. Nil when the chapter has not loaded.
    @discardableResult
    func showPage(_ page: Int) async -> EPUBPageState? {
        guard didFinishInitialLoad else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.__amgiShowPage ? await window.__amgiShowPage(page) : null;",
            arguments: ["page": page],
            contentWorld: .page
        )
        guard let state = EPUBPageState(scriptResult: result) else { return nil }
        noteReported(page: state.page, count: state.pageCount)
        return state
    }

    /// What the page is showing right now, measured from the page.
    func pageState() async -> EPUBPageState? {
        guard didFinishInitialLoad else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.__amgiPageState ? window.__amgiPageState() : null;",
            arguments: [:],
            contentWorld: .page
        )
        return EPUBPageState(scriptResult: result)
    }

    /// Whether a turn in this direction stays inside the chapter.
    func canTurn(_ direction: PageDirection) -> Bool {
        switch direction {
        case .forward: currentPageIndex < pageCount - 1
        case .backward: currentPageIndex > 0
        }
    }

    var isAtLastPage: Bool { !canTurn(.forward) }

    var isAtFirstPage: Bool { !canTurn(.backward) }

    var isReadyForPaging: Bool {
        didFinishInitialLoad
    }

    func requestSelectionForNote() {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self,
                  let text = result as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.pageDelegate?.epubChapter(self, didSelectTextForNote: trimmed)
        }
    }

    /// Apply a batch of stored marks to the loaded chapter.
    ///
    /// Returns how many actually landed. A mark that no longer resolves is
    /// *not* an error: the whole point of the quote fallback is that a
    /// highlight survives the book being re-extracted, and a stale mark should
    /// quietly stop being drawn rather than block the page.
    /// Supplies the marks for this chapter. Set by the host from the view's
    /// command bus, because the controller cannot reach the annotation store.
    var annotationProvider: (@MainActor (Int64) async -> [[String: Any]])?

    /// Forwards a selection-menu action to the host. The controller owns the
    /// menu but not the book or the annotation store, so it relays rather
    /// than acting.
    func readerSelectionMenu(
        _ action: ReaderSelectionAction,
        payload: ReaderSelectionPayload
    ) {
        switch action {
        case .copy:
            UIPasteboard.general.string = payload.text
        case .lookUp:
            pageDelegate?.epubChapter(
                self,
                didSelectText: payload.text,
                token: payload.token,
                sentence: payload.sentence,
                anchor: payload.anchor
            )
        case .highlight:
            selectionHighlightHandler?(payload)
        case .bookmark:
            selectionBookmarkHandler?(payload)
        }
    }

    /// Card commands never open a sheet: they go straight to the host's draft
    /// stack, and the selection is cleared so the next long press starts
    /// clean — the reader keeps reading.
    func readerSelectionCard(_ command: ReaderCardMenuCommand, payload: ReaderSelectionPayload) {
        selectionCardHandler?(command, payload)
        webView.evaluateJavaScript("window.getSelection() && window.getSelection().removeAllRanges();")
    }

    /// Drops any selection, so a page handed back to drawing pictures does
    /// not draw it into them.
    func clearSelection() {
        webView.evaluateJavaScript("window.getSelection() && window.getSelection().removeAllRanges();")
    }

    var cardMenuContext: ReaderCardMenuContext {
        cardMenuContextProvider?() ?? ReaderCardMenuContext()
    }

    /// Set by the host to persist a highlight or bookmark from the selection
    /// menu. Separate from the delegate because a highlight is a local mark,
    /// not a lookup.
    var selectionHighlightHandler: ((ReaderSelectionPayload) -> Void)?
    var selectionBookmarkHandler: ((ReaderSelectionPayload) -> Void)?
    /// Set by the host: card commands and the draft stack they act on.
    var selectionCardHandler: ((ReaderCardMenuCommand, ReaderSelectionPayload) -> Void)?
    var cardMenuContextProvider: (() -> ReaderCardMenuContext)?
    /// Set by the host: every selection report, and nil when it clears. Lets a
    /// selection dragged onto the dock keep its anchor.
    var selectionReportHandler: ((ReaderSelectionPayload?) -> Void)?
    /// Set by the host: a tap on a card or card-draft mark, with the mark's id
    /// and kind. Lets a hollow mark resume the draft it belongs to.
    /// A capture mark was tapped: its id, its kind, and where, in window
    /// coordinates.
    var markTapHandler: ((String, String, CGPoint) -> Void)?

    /// Called when the user swipes horizontally past the threshold. The host
    /// owns every page turn, so this is the only gesture that advances the
    /// book — which is what makes curl, slide and fade all reachable the same
    /// way instead of only the ones `UIPageViewController` happens to support.
    var onSwipeTurn: ((PageDirection) -> Void)?

    /// Installs the swipe recogniser.
    ///
    /// This used to be `scrollView.isPagingEnabled`, which only ever slid and
    /// could not be curled. A dedicated recogniser also keeps the effect and
    /// the gesture in one place: whichever transition is selected, a swipe
    /// forward turns forward and a swipe back turns back.
    private func installSwipeRecogniser() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        pan.delegate = self
        // The web view's own scroll view has a pan of its own for text
        // selection; ours must win for horizontal drags that begin as a
        // swipe, or the page would slide instead of turning.
        pan.cancelsTouchesInView = true
        pan.maximumNumberOfTouches = 1
        webView.addGestureRecognizer(pan)
        swipeRecogniser = pan
    }

    private var swipeRecogniser: UIPanGestureRecognizer?

    /// Horizontal distance that counts as a turn, as a fraction of the page
    /// width. Roughly a quarter of the page: enough to be deliberate, small
    /// enough that a tap-and-drag on a word is not read as a swipe.
    private static let swipeThresholdFraction: CGFloat = 0.22

    @objc private func handleSwipe(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        switch recognizer.state {
        case .began:
            // A live text selection means the user is selecting text, not
            // turning a page, so the selection wins and the swipe is dropped.
            // The page reports selection state through `wordSelection`, which
            // is the only way to know synchronously — `evaluateJavaScript`
            // cannot be called from a gesture callback.
            if hasLiveSelection { return }
        case .ended, .cancelled:
            if hasLiveSelection { return }
            let translation = recognizer.translation(in: view)
            let width = max(1, view.bounds.width)
            // Require the drag to be predominantly horizontal, so a vertical
            // scroll or a diagonal flick is not mistaken for a page turn.
            guard abs(translation.x) > abs(translation.y) * 1.5 else { return }
            let threshold = width * Self.swipeThresholdFraction
            guard abs(translation.x) > threshold else { return }
            onSwipeTurn?(translation.x < 0 ? .forward : .backward)
        default:
            break
        }
    }

    /// Whether the page currently holds a non-collapsed text selection.
    /// Maintained from the `wordSelection` message, which fires on every
    /// `selectionchange` including the one that clears a selection.
    private var hasLiveSelection = false

    /// Prints the page number and running head onto the page itself.
    ///
    /// Drawn in the document rather than in native chrome so it uses the
    /// book's own face and sits on the page's own margins. That is what makes
    /// it read as part of the book instead of a control floating over it.
    func applyPageFurniture(page: Int, runningHead: String, total: Int? = nil) {
        let json: String
        var payload: [String: Any] = ["page": page, "head": runningHead]
        if let total { payload["total"] = total }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            return
        }
        webView.evaluateJavaScript(
            "window.__amgiSetPageFurniture && window.__amgiSetPageFurniture(\(json));",
            completionHandler: nil
        )
    }

    /// Remembers the page's selection report. Called by the bridge when the
    /// page reports a non-collapsed selection. Nothing is presented: WebKit
    /// shows its own menu, and asks `ReaderWebView` for the reader's items.
    fileprivate func noteSelection(_ payload: ReaderSelectionPayload) {
        latestSelection = payload
        selectionReportHandler?(payload)
    }

    /// The reader's items for WebKit's menu.
    ///
    /// Built from the last report when there is one. A long press can raise
    /// the menu before the page's debounced report lands; the items are still
    /// offered then, because each one reads the live selection when chosen.
    private func selectionMenuElements() -> [UIMenuElement] {
        let shape = latestSelection ?? ReaderSelectionPayload(
            text: "…",
            token: "",
            sentence: "",
            anchor: ReaderSourceAnchor(bookID: content.bookID, quote: "")
        )
        let entries = ReaderSystemSelectionMenu.entries(for: shape, context: cardMenuContext)
        let actions = ReaderSelectionMenuActions(
            perform: { [weak self] action in
                self?.withLiveSelection { self?.readerSelectionMenu(action, payload: $0) }
            },
            card: { [weak self] command in
                self?.withLiveSelection { self?.readerSelectionCard(command, payload: $0) }
            }
        )
        return ReaderSystemSelectionMenu.elements(for: entries, actions: actions)
    }

    /// Reads the selection as it is now, falling back to the last report.
    private func withLiveSelection(_ body: @escaping @MainActor (ReaderSelectionPayload) -> Void) {
        let fallback = latestSelection
        webView.evaluateJavaScript(
            "window.__amgiDescribeSelection ? window.__amgiDescribeSelection() : null;"
        ) { [weak self] result, _ in
            MainActor.assumeIsolated {
                if let self, let payload = self.selectionPayload(from: result) ?? fallback {
                    body(payload)
                }
            }
        }
    }

    /// Decodes the dictionary the page script posts for a selection.
    fileprivate func selectionPayload(from body: Any?) -> ReaderSelectionPayload? {
        guard let dict = body as? [String: Any] else { return nil }
        let selection = (dict["selection"] as? String) ?? ""
        guard !selection.isEmpty else { return nil }
        return ReaderSelectionPayload(
            text: selection,
            token: (dict["token"] as? String) ?? selection,
            sentence: (dict["sentence"] as? String) ?? selection,
            anchor: resolvedAnchor(from: dict["anchor"])
        )
    }

    /// Selection state, mirrored from the page so the swipe recogniser can
    /// consult it synchronously. A gesture callback cannot call back into the
    /// web view, and treating a live selection as a page turn would yank the
    /// page out from under the user's finger mid-selection.
    fileprivate func noteSelectionBegan() {
        hasLiveSelection = true
    }

    fileprivate func noteSelectionCleared() {
        hasLiveSelection = false
        latestSelection = nil
        selectionRects = []
        selectionReportHandler?(nil)
    }

    /// Pull the chapter's marks and paint them.
    ///
    /// Runs after the document loads, since the applier walks the token spans
    /// the injected script creates. A book whose script failed to tokenise
    /// simply gets no marks, rather than an error.
    func applyAnnotationsForCurrentChapter() {
        guard let annotationProvider else { return }
        let chapterID = content.chapterID
        Task { [weak self] in
            let marks = await annotationProvider(chapterID)
            guard let self, !Task.isCancelled else { return }
            applyMarks(marks)
        }
    }

    @discardableResult
    func applyMarks(_ marks: [[String: Any]]) -> Int {
        guard !marks.isEmpty else {
            webView.evaluateJavaScript("window.__amgiApplyMarks && window.__amgiApplyMarks([]);")
            return 0
        }
        let json = marksJSON(marks)
        var applied = 0
        webView.evaluateJavaScript(
            "window.__amgiApplyMarks ? window.__amgiApplyMarks(\(json)) : 0;"
        ) { result, _ in
            applied = (result as? Int) ?? 0
        }
        return applied
    }

    /// Asks the page for an anchor at the current viewport.
    ///
    /// The page is the only thing that knows where it is scrolled to, so a
    /// bookmark captured without a tap has to round-trip through it. The
    /// completion is main-actor isolated to match the delegate callbacks.
    func requestCurrentAnchor(_ completion: @escaping @MainActor (ReaderSourceAnchor?) -> Void) {
        webView.evaluateJavaScript("window.__amgiCurrentAnchor && window.__amgiCurrentAnchor();") {
            [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard var anchor = ReaderSourceAnchor(scriptPayload: result) else {
                    completion(nil)
                    return
                }
                // The script cannot know the library's identity; stamp it on.
                anchor.bookID = self.content.bookID
                anchor.chapterID = self.content.chapterID
                anchor.chapterHref = self.content.chapterHref
                completion(anchor)
            }
        }
    }

    private func marksJSON(_ marks: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: marks),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    fileprivate func applyStyleTokens() {
        let mode = styleTokens.verticalMode ? "vertical-rl" : "horizontal-tb"
        let escapedFontFamily = styleTokens.fontFamilyCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
          var r = document.documentElement;
          r.style.setProperty('--reader-fg', '\(styleTokens.foreground)');
          r.style.setProperty('--reader-bg', '\(styleTokens.background)');
          r.setAttribute('data-amgi-theme', '\(styleTokens.theme)');
          r.style.setProperty('--reader-font-size', '\(styleTokens.fontSizePx)px');
          r.style.setProperty('--reader-line-height', '\(styleTokens.lineHeight)');
          r.style.setProperty('--reader-padding', '\(styleTokens.paddingPx)px');
          r.style.setProperty('--reader-page-margin', '\(styleTokens.pageMarginPx)px');
          r.style.setProperty('--reader-page-padding', '\(styleTokens.paddingPx)px');
          r.style.setProperty('--reader-writing-mode', '\(mode)');
          r.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
          r.style.setProperty('--reader-text-align', '\(styleTokens.textAlign)');
          r.style.setProperty('--reader-press', '\(styleTokens.pressTintCSS)');
          // Vertical insets keep text clear of the floating chrome. Passed as
          // CSS so the page recomputes on rotation instead of needing a reload.
          r.style.setProperty('--reader-inset-top', '\(styleTokens.insetTopPx)px');
          r.style.setProperty('--reader-inset-bottom', '\(styleTokens.insetBottomPx)px');
          r.style.setProperty('--reader-head-y', '\(styleTokens.headCenterPx)px');
          r.style.setProperty('--reader-foot-y', '\(styleTokens.footCenterPx)px');
          // Gate the font override on the user having picked a family. Empty
          // `fontFamilyCSS` means "Book", and a book that embeds a serif face
          // should keep it — that is what Apple Books does.
          r.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
          r.setAttribute(
            'data-amgi-honour-book-font',
            '\(styleTokens.fontFamilyCSS.isEmpty ? "1" : "0")'
          );
          r.setAttribute('data-amgi-native-furniture', '1');
          r.setAttribute('data-amgi-page-columns', '\(styleTokens.pageColumns == 2 ? 2 : 1)');
          if (typeof window.__amgiRelayout === 'function') { window.__amgiRelayout(); }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error { Log.reader.error("relayout script failed: \(error)") }
        }
        applyHostBackgroundColor()
    }

    /// Stamps the book/chapter identity onto an anchor the page produced.
    ///
    /// The injected script runs inside the page and has no handle on the
    /// library's chapter IDs, so only this layer can complete the anchor.
    /// A malformed payload yields nil rather than a partial anchor — an
    /// anchor that points at the wrong words is worse than none.
    fileprivate func resolvedAnchor(from payload: Any?) -> ReaderSourceAnchor? {
        guard var anchor = ReaderSourceAnchor(scriptPayload: payload) else { return nil }
        anchor.bookID = content.bookID
        anchor.chapterID = content.chapterID
        anchor.chapterHref = content.chapterHref
        return anchor
    }

    fileprivate func consumePendingRestore() {
        let fraction = pendingRestoreFraction
        let pageIndex = pendingPageIndex
        guard fraction != nil || pageIndex != nil else { return }
        ReaderTelemetry.log("restore", [
            "chapter": chapterIndex, "fraction": fraction.map { String($0) } ?? "-",
            "page": pageIndex.map { String($0) } ?? "-", "measure": isMeasurementOnly,
        ])
        pendingRestoreFraction = nil
        pendingPageIndex = nil
        // Wait for the page's own layout pass rather than guessing at 250ms.
        // Two nested requestAnimationFrames: the first fires before the
        // pending layout is committed, the second after — at which point the
        // column count `__amgiRelayout` computes is final and the scroll
        // target is meaningful. The old fixed delay silently restored the
        // wrong position whenever layout took longer than that.
        let js = """
        (function() {
          requestAnimationFrame(function() {
            requestAnimationFrame(function() {
              if (typeof window.__amgiRelayout === 'function') { window.__amgiRelayout(); }
              if (typeof window.__amgiScrollToPage === 'function' && \(pageIndex == nil ? "false" : "true")) {
                window.__amgiScrollToPage(\(pageIndex ?? 0));
              } else if (typeof window.__amgiScrollToFraction === 'function') {
                window.__amgiScrollToFraction(\(fraction ?? 0));
              }
            });
          });
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error { Log.reader.error("scrollToFraction script failed: \(error)") }
        }
    }

    fileprivate func consumePendingAnchor() {
        if let anchor = pendingAnchor {
            pendingAnchor = nil
            scroll(to: anchor)
        }
    }

}

private extension EPUBChapterPageController {
    // MARK: - Bundle resource loading

    static func bundledCSS() -> String? {
        EPUBReaderBundledResources.css()
    }

    static func bundledJS() -> String? {
        EPUBReaderBundledResources.interactionJS()
    }

    static func interactionJS() -> String? {
        EPUBReaderBundledResources.interactionJS()
    }

    static var emptyTapScript: String {
        EPUBReaderBundledResources.emptyTapScript
    }

    static func injectStyleSnippet(css: String) -> String {
        EPUBReaderBundledResources.injectStyleSnippet(css: css)
    }
}

// MARK: - Script + scroll bridge

/// Bridges WKScriptMessageHandler, WKNavigationDelegate, and
/// UIScrollViewDelegate. Token and empty taps both originate in the document
/// script, so they share one gesture and cannot race a native recognizer.
@MainActor
final class ScriptBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
                          UIScrollViewDelegate {
    private weak var owner: EPUBChapterPageController?

    /// Root the loaded chapter may read from, captured at init.
    ///
    /// Held here rather than read through `owner` so the navigation policy
    /// does not depend on the owner still being alive, and so the value cannot
    /// change under it: a bridge belongs to exactly one chapter controller.
    let readAccessURL: URL?

    init(owner: EPUBChapterPageController) {
        self.owner = owner
        self.readAccessURL = owner.content.readAccessURL
    }

    // MARK: WKNavigationDelegate

    /// Gate every navigation the book attempts. Without this, a `<a href>`,
    /// a `window.location` assignment, or a book script can navigate the
    /// reader anywhere — including `file://` URLs inside the read scope we
    /// granted the page, or straight off the device over http(s).
    ///
    /// The `decisionHandler` type must match WebKit's declaration exactly
    /// (`@escaping @MainActor @Sendable`). Writing plain `@escaping` compiles
    /// to a "nearly matches" *warning* and the method is then never called, so
    /// the reader silently runs with no navigation policy at all.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let decision = EPUBNavigationPolicy.decide(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
            readAccessURL: readAccessURL
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .openExternally(let url):
            // An author-placed link is user intent, so hand it to the system
            // rather than loading it in the reader.
            decisionHandler(.cancel)
            EPUBNavigationPolicy.openInSystem(url)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process was killed (usually memory, with several books'
        // worth of pages alive). Without this the page stayed blank.
        ReaderTelemetry.log("webcontent.terminated", ["page": owner?.telemetryTag ?? "?"])
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ReaderTelemetry.log("load.finished", ["page": owner?.telemetryTag ?? "?"])
        owner?.markInitialLoadFinished()
        // Push viewport size first so the CSS column container is sized
        // correctly *before* applyStyleTokens triggers a relayout. Then
        // apply theme + typography, then restore saved progress.
        owner?.pushPageSizeIfChanged(force: true)
        owner?.applyStyleTokens()
        owner?.applyChromeVisibility()
        // Marks last: they are applied by walking the token spans, so a mark
        // applied before tokenisation would silently match nothing.
        owner?.applyAnnotationsForCurrentChapter()
        owner?.consumePendingRestore()
        owner?.consumePendingAnchor()
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit delivers script messages on the main thread; message.name /
        // .body are @MainActor. assumeIsolated reads them and dispatches
        // synchronously — no Task hop needed.
        MainActor.assumeIsolated {
            // A book can author its own <iframe>, and anything inside it
            // shares the page's script world. Only the main frame's own
            // document is trusted to drive the reader.
            guard message.frameInfo.isMainFrame else { return }
            self.handle(name: message.name, body: message.body)
        }
    }

    // MARK: UIScrollViewDelegate (page bookkeeping)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Held at the origin: see the scroll-view setup in `loadView`.
        guard scrollView.contentOffset != .zero else { return }
        ReaderTelemetry.log("scrollview.reset", [
            "page": owner?.telemetryTag ?? "?",
            "x": Int(scrollView.contentOffset.x), "y": Int(scrollView.contentOffset.y),
        ])
        scrollView.contentOffset = .zero
    }


}

private extension ScriptBridge {
    func handle(name: String, body: Any) {
        guard let owner else { return }
        switch name {
        case "pageInfo":
            guard let dict = body as? [String: Any],
                  let pageIndex = dict["pageIndex"] as? Int,
                  let pageCount = dict["pageCount"] as? Int else { return }
            owner.noteReported(page: pageIndex, count: pageCount)
            owner.pageDelegate?.epubChapter(owner, didReportPageInfoIndex: pageIndex, pageCount: pageCount)
        case "progress":
            // Progress only: page and count come from `pageInfo`.
            guard let dict = body as? [String: Any],
                  let pageIndex = dict["pageIndex"] as? Int,
                  let fraction = dict["progressFraction"] as? Double else { return }
            owner.pageDelegate?.epubChapter(owner, didReportProgressFraction: fraction, pageIndex: pageIndex)
        case "wordSelection":
            // A long press produced a live selection. WebKit shows its own
            // menu; this tells the controller what was selected so that menu
            // can carry the Anki actions. A single tap never reaches here.
            guard body is [String: Any] else { return }
            guard let payload = owner.selectionPayload(from: body) else {
                // The page also reports a *cleared* selection, which is how
                // the swipe recogniser learns a page turn is allowed again.
                owner.noteSelectionCleared()
                return
            }
            owner.noteSelectionBegan()
            owner.noteSelectionRects((body as? [String: Any])?["rects"])
            // The lookup sheet must NOT open here: a long press that
            // immediately threw up a dictionary would be the same mistake as
            // tap-to-lookup, just with an extra step. The delegate hears about
            // it only when Look Up is chosen from the menu.
            owner.noteSelection(payload)
        case "markTap":
            guard let dict = body as? [String: Any],
                  let id = dict["id"] as? String,
                  let kind = dict["kind"] as? String else { return }
            let x = (dict["x"] as? Double) ?? 0
            let y = (dict["y"] as? Double) ?? 0
            let point = owner.webView.convert(CGPoint(x: x, y: y), to: nil)
            owner.markTapHandler?(id, kind, point)
        case "emptyTap":
            guard let number = body as? NSNumber else { return }
            owner.pageDelegate?.epubChapterDidTapEmptySpace(
                owner,
                atRelativeX: CGFloat(truncating: number)
            )
        default:
            break
        }
    }
}

#endif
