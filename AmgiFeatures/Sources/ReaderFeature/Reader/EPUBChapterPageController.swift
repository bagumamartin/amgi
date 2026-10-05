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
              s.textContent = `\(escaped)
              html[data-amgi-page-columns="2"] {
                column-width: 50vw !important;
                -webkit-column-width: 50vw !important;
              }`;
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
final class EPUBChapterPageController: UIViewController, ReaderSelectionMenuPresenting,
                                      UIGestureRecognizerDelegate {
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

    private var webView: WKWebView!
    private var bridge: ScriptBridge!
    /// The long-press selection menu. Owned here so its lifetime matches the
    /// chapter's web view; without a strong reference the interaction would be
    /// deallocated the moment `loadView` returned.
    private var selectionMenu: ReaderSelectionMenuController?
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

        config.userContentController = userContent
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: config)
        // Paging is driven by the host, not by UIScrollView.
        //
        // `isPagingEnabled` was the reason the selected page transition only
        // half worked: the scroll view snapped between columns on its own, so
        // every intra-chapter turn was a hard slide no matter what the user
        // had chosen, and it could not be curled, faded, or eased. Letting the
        // host own the offset means one pipeline handles every turn — inside
        // a chapter and across a boundary — and the chosen effect applies to
        // all of them.
        webView.scrollView.isPagingEnabled = false
        webView.scrollView.isScrollEnabled = !isPageCurlManaged
        webView.scrollView.decelerationRate = .fast
        // Bounces stay on so a drag past the edge still feels alive, but the
        // deceleration is disabled: a fling should not slide a page, it should
        // be interpreted as a swipe by the host's own recogniser.
        webView.scrollView.alwaysBounceHorizontal = true
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
        self.view = webView
        if !isPageCurlManaged { installSwipeRecogniser() }
        // Long press is WebKit's own selection gesture; the menu sits on top
        // of it so the system callout and the Anki actions coexist.
        selectionMenu = ReaderSelectionMenuController(
            presenter: self,
            anchorView: webView
        )
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

        let previousPageWidth = lastPushedPageSize.width
        let hasPendingPosition = pendingPageIndex != nil || pendingRestoreFraction != nil
        let currentOffsetX = webView.scrollView.contentOffset.x
        let previousIndex: Int
        if previousPageWidth > 0 {
            previousIndex = Int(round(currentOffsetX / previousPageWidth))
        } else {
            previousIndex = 0
        }

        lastPushedPageSize = size

        // JS owns --page-width / --page-height (driven from window.innerWidth
        // / innerHeight inside __amgiRelayout → syncPageVars). Swift only
        // pokes the relayout hook so we re-snap to the right column after
        // rotation or safe-area changes.
        let js = """
        (function() {
          var n = (typeof window.__amgiRelayout === 'function') ? window.__amgiRelayout() : 1;
          return n;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self else { return }
            // Re-snap to the previously-current page after the relayout
            // settles. Done in the next runloop tick so the new
            // contentSize.width has propagated to the scroll view.
            DispatchQueue.main.async {
                let newWidth = self.webView.scrollView.bounds.width
                guard newWidth > 0 else { return }
                guard !hasPendingPosition else { return }
                let target = CGFloat(previousIndex) * newWidth
                let maxX = max(0, self.webView.scrollView.contentSize.width - newWidth)
                self.webView.scrollView.setContentOffset(
                    CGPoint(x: min(target, maxX), y: 0),
                    animated: false
                )
            }
        }
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

    /// Width of one page in points. Every offset and page index is derived
    /// from this so the host and the page never disagree about what "page 3"
    /// means.
    private var pageWidth: CGFloat {
        let width = webView.scrollView.bounds.width
        return width > 1 ? width : webView.bounds.width
    }

    /// Number of pages this chapter currently lays out to.
    var pageCount: Int {
        let width = pageWidth
        guard width > 1, webView.scrollView.contentSize.width > 1 else { return 1 }
        return max(1, Int(ceil(webView.scrollView.contentSize.width / width - 0.01)))
    }

    /// Zero-based index of the page on screen, derived from the offset so it
    /// cannot drift from what the user sees.
    var currentPageIndex: Int {
        let width = pageWidth
        guard width > 1 else { return 0 }
        let raw = webView.scrollView.contentOffset.x / width
        return min(max(0, Int(round(raw))), max(0, pageCount - 1))
    }

    /// Moves to a specific page, clamped to the chapter. Returns the page
    /// actually reached so the caller can tell whether a turn crossed a
    /// chapter boundary.
    @discardableResult
    func setPage(_ index: Int, animated: Bool) -> Int {
        let width = pageWidth
        guard width > 1 else { return 0 }
        let clamped = min(max(index, 0), max(0, pageCount - 1))
        let offset = CGPoint(x: CGFloat(clamped) * width, y: 0)
        if animated {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                self.webView.scrollView.setContentOffset(offset, animated: false)
            }
        } else {
            webView.scrollView.setContentOffset(offset, animated: false)
        }
        return clamped
    }

    /// Whether a turn in this direction stays inside the chapter.
    func canTurn(_ direction: PageDirection) -> Bool {
        switch direction {
        case .forward: currentPageIndex < pageCount - 1
        case .backward: currentPageIndex > 0
        }
    }

    /// A snapshot of the WebView page, used for the fade transition. Keeping
    /// the capture inside the page controller avoids duplicating fixed SwiftUI
    /// controls during the animation.
    func snapshot(ofPage index: Int) -> UIImage? {
        let width = pageWidth
        guard width > 1 else { return nil }
        let previousOffset = webView.scrollView.contentOffset
        let target = CGPoint(x: CGFloat(min(max(index, 0), max(0, pageCount - 1))) * width, y: 0)
        // Snapping first and sampling after a layout pass is the only way to
        // get a synchronous image of a page that is not currently on screen.
        webView.scrollView.setContentOffset(target, animated: false)
        webView.layoutIfNeeded()
        defer { webView.scrollView.setContentOffset(previousOffset, animated: false) }
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { _ in
            webView.layer.render(in: UIGraphicsGetCurrentContext()!)
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
        case .lookUp, .addNote:
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

    /// Set by the host to persist a highlight or bookmark from the selection
    /// menu. Separate from the delegate because a highlight is a local mark,
    /// not a lookup.
    var selectionHighlightHandler: ((ReaderSelectionPayload) -> Void)?
    var selectionBookmarkHandler: ((ReaderSelectionPayload) -> Void)?

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

    /// Shows the selection menu. Called by the bridge when the page reports
    /// a non-collapsed selection.
    fileprivate func presentSelectionMenu(for payload: ReaderSelectionPayload) {
        selectionMenu?.present(for: payload)
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
          // Gate the font override on the user having picked a family. Empty
          // `fontFamilyCSS` means "Book", and a book that embeds a serif face
          // should keep it — that is what Apple Books does.
          r.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
          r.setAttribute(
            'data-amgi-honour-book-font',
            '\(styleTokens.fontFamilyCSS.isEmpty ? "1" : "0")'
          );
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.markInitialLoadFinished()
        // Push viewport size first so the CSS column container is sized
        // correctly *before* applyStyleTokens triggers a relayout. Then
        // apply theme + typography, then restore saved progress.
        owner?.pushPageSizeIfChanged(force: true)
        owner?.applyStyleTokens()
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
        if scrollView.contentOffset.y != 0 {
            scrollView.contentOffset.y = 0
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        emitPageInfo(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { emitPageInfo(scrollView) }
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
            owner.pageDelegate?.epubChapter(owner, didReportPageInfoIndex: pageIndex, pageCount: pageCount)
        case "progress":
            // progress events only update the progress fraction.
            // UIScrollViewDelegate (emitPageInfo) is the single source of
            // truth for pageIndex / pageCount — emitting them from here
            // too caused the host counter to flicker during a swipe.
            guard let dict = body as? [String: Any],
                  let pageIndex = dict["pageIndex"] as? Int,
                  let fraction = dict["progressFraction"] as? Double else { return }
            owner.pageDelegate?.epubChapter(owner, didReportProgressFraction: fraction, pageIndex: pageIndex)
        case "wordSelection":
            // A long press produced a live selection. WebKit is already
            // showing its own callout; this tells the host what was selected
            // so it can extend that menu with the Anki actions rather than
            // replacing it. A single tap never reaches here.
            guard let dict = body as? [String: Any] else { return }
            let selection = (dict["selection"] as? String) ?? ""
            let token = (dict["token"] as? String) ?? selection
            let sentence = (dict["sentence"] as? String) ?? selection
            guard !selection.isEmpty else {
                // The page also reports a *cleared* selection, which is how
                // the swipe recogniser learns a page turn is allowed again.
                owner.noteSelectionCleared()
                return
            }
            owner.noteSelectionBegan()
            // Only the menu is shown. The lookup sheet must NOT open here: a
            // long press that immediately threw up a dictionary would be the
            // same mistake as tap-to-lookup, just with an extra step. The
            // delegate is notified from `performSelectionAction` when the user
            // actually picks Look Up or Add Note.
            owner.presentSelectionMenu(
                for: ReaderSelectionPayload(
                    text: selection,
                    token: token,
                    sentence: sentence,
                    anchor: owner.resolvedAnchor(from: dict["anchor"])
                )
            )
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

    func emitPageInfo(_ scrollView: UIScrollView) {        guard let owner else { return }
        let viewport = max(1, scrollView.bounds.width)
        let pageIndex = Int(round(scrollView.contentOffset.x / viewport))
        let totalPages = max(1, Int(round(scrollView.contentSize.width / viewport)))
        owner.pageDelegate?.epubChapter(owner, didReportPageInfoIndex: pageIndex, pageCount: totalPages)
        let denom = Double(max(1, totalPages - 1))
        let fraction = min(1, max(0, Double(pageIndex) / denom))
        owner.pageDelegate?.epubChapter(owner, didReportProgressFraction: fraction, pageIndex: pageIndex)
    }
}

#endif
