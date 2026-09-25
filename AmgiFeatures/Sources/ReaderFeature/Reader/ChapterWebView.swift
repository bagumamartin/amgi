#if os(iOS)
import AmgiReader
import AmgiTheme
import AmgiAppCore
import Sharing
import SwiftUI
import WebKit

struct ChapterWebView: UIViewRepresentable {
    let html: String
    /// 0..1 fraction to scroll to once the page finishes loading. Read once
    /// per appearance — set to nil after the initial restore.
    let initialProgress: Double?
    @Binding var progress: Double
    let isPaginated: Bool
    let pageTurnRequest: ReaderPageTurnRequest?
    let onPageInfo: (Int, Int) -> Void
    let onPageBoundary: (ReaderPageDirection) -> Void
    /// Called with a tapped phrase (the engine does its own deinflection
    /// and word-segmentation, so we forward a generous chunk starting at
    /// the tap point rather than a pre-extracted word — handles CJK,
    /// where word boundaries don't exist at the DOM level). nil disables
    /// the tap gesture entirely (controlled by the user pref).
    let onTapLookup: ((String) -> Void)?
    /// Called with the user's current text selection when the toolbar
    /// "make note" button fires the `.amgiReaderRequestSelection`
    /// notification. nil ignores the request.
    let onSelectionForNote: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            progress: $progress,
            isPaginated: isPaginated,
            onPageInfo: onPageInfo,
            onPageBoundary: onPageBoundary,
            onTapLookup: onTapLookup,
            onSelectionForNote: onSelectionForNote
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        if onTapLookup != nil {
            userContent.add(context.coordinator, name: "amgiLookup")
            userContent.addUserScript(WKUserScript(
                source: tapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        webView.isOpaque = false
        context.coordinator.attach(webView: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingInitialProgress = initialProgress
        context.coordinator.pageTurnRequest = pageTurnRequest
        context.coordinator.updatePagination(isPaginated)
        context.coordinator.consumePageTurnRequestIfNeeded()
        // The host builds the HTML in a `.task`, so the very first update
        // arrives empty. Loading it would flash a blank document before the
        // real one lands one runloop later.
        guard !html.isEmpty else { return }
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            context.coordinator.didFinishLoad = false
            context.coordinator.didApplyInitialProgress = false
            context.coordinator.lastReportedPageIndex = -1
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            // The saved progress now resolves asynchronously, so it can
            // land after `didFinish` — apply it late, once per load.
            context.coordinator.applyPendingInitialProgressIfLoaded()
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Single-tap → grab a clean phrase starting at the tap caret and
    /// post it to native. Long-press still triggers WKWebView's native
    /// selection so copy/paste keeps working. Skip when there's an
    /// active selection so tapping to dismiss the selection doesn't
    /// also fire a lookup.
    ///
    /// The phrase is cut at the next sentence boundary using `Intl.Segmenter`
    /// when available — this gives the dictionary engine a complete clause
    /// (typically a few words / a clause) to scan rather than an arbitrary
    /// 32-char window that often splits a Hangul/CJK token mid-character.
    /// Falls back to the legacy 32-char chunk on browsers without Segmenter
    /// (mostly old WebKit; current iOS WKWebView ships it).
    private var tapScript: String {
        """
        document.addEventListener('click', function(e) {
          const sel = window.getSelection();
          if (sel && sel.toString().length > 0) { return; }
          const range = document.caretRangeFromPoint(e.clientX, e.clientY);
          if (!range) { return; }

          // Walk forward through text nodes from the tap caret until we
          // have enough characters for the segmenter to find a sentence
          // boundary. 96 is generous — Segmenter cuts at the first
          // boundary anyway, and the engine's scanLength still caps the
          // match.
          let phrase = '';
          let node = range.startContainer;
          let offset = range.startOffset;
          while (node && phrase.length < 96) {
            if (node.nodeType === Node.TEXT_NODE) {
              const t = node.nodeValue || '';
              phrase += t.substring(offset);
              offset = 0;
            }
            if (node.firstChild) {
              node = node.firstChild;
            } else {
              while (node && !node.nextSibling) { node = node.parentNode; }
              node = node && node.nextSibling;
            }
          }
          phrase = phrase.replace(/\\s+/g, ' ').trim();
          if (phrase.length === 0) { return; }

          // Trim to the first sentence using Intl.Segmenter — gives the
          // engine a complete clause without trailing junk. Locale
          // `und` lets the runtime pick rules per script.
          if (typeof Intl !== 'undefined' && Intl.Segmenter) {
            try {
              const seg = new Intl.Segmenter('und', { granularity: 'sentence' });
              const first = seg.segment(phrase)[Symbol.iterator]().next();
              if (first.value && first.value.segment) {
                phrase = first.value.segment.trim();
              }
            } catch (err) {
              // Fall through with the raw phrase.
            }
          }

          if (phrase.length > 0) {
            window.webkit.messageHandlers.amgiLookup.postMessage(phrase);
          }
        }, true);
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        var pendingInitialProgress: Double?
        var loadedHTML: String?
        var didFinishLoad = false
        var didApplyInitialProgress = false
        var isPaginated: Bool
        var pageTurnRequest: ReaderPageTurnRequest?
        var handledPageTurnSequence = 0
        fileprivate var lastReportedPageIndex = -1
        @Binding var progress: Double
        let onPageInfo: (Int, Int) -> Void
        let onPageBoundary: (ReaderPageDirection) -> Void
        let onTapLookup: ((String) -> Void)?
        let onSelectionForNote: ((String) -> Void)?
        private weak var webView: WKWebView?
        private var selectionObserver: (any NSObjectProtocol)?
        /// Live while waiting for the page to report a real content size.
        private var contentSizeObservation: NSKeyValueObservation?

        init(
            progress: Binding<Double>,
            isPaginated: Bool,
            onPageInfo: @escaping (Int, Int) -> Void,
            onPageBoundary: @escaping (ReaderPageDirection) -> Void,
            onTapLookup: ((String) -> Void)?,
            onSelectionForNote: ((String) -> Void)?
        ) {
            self._progress = progress
            self.isPaginated = isPaginated
            self.onPageInfo = onPageInfo
            self.onPageBoundary = onPageBoundary
            self.onTapLookup = onTapLookup
            self.onSelectionForNote = onSelectionForNote
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            configureScrollView(webView.scrollView)
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .amgiReaderRequestSelection,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue, so assumeIsolated is safe and
                // keeps fetchSelection() synchronous.
                MainActor.assumeIsolated { self?.fetchSelection() }
            }
        }

        func detach() {
            if let observer = selectionObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            selectionObserver = nil
            contentSizeObservation = nil
            webView = nil
        }

        func updatePagination(_ enabled: Bool) {
            guard isPaginated != enabled else { return }
            isPaginated = enabled
            guard let scrollView = webView?.scrollView else { return }
            configureScrollView(scrollView)
            if didFinishLoad { applyPaginationStyle() }
        }

        func consumePageTurnRequestIfNeeded() {
            guard isPaginated,
                  didFinishLoad,
                  let request = pageTurnRequest,
                  request.sequence > handledPageTurnSequence,
                  let scrollView = webView?.scrollView else { return }
            handledPageTurnSequence = request.sequence
            paginate(scrollView, direction: request.direction)
        }

        private func configureScrollView(_ scrollView: UIScrollView) {
            scrollView.isPagingEnabled = isPaginated
            scrollView.alwaysBounceHorizontal = isPaginated
            scrollView.alwaysBounceVertical = !isPaginated
            scrollView.showsHorizontalScrollIndicator = isPaginated
        }

        private func hasScrollableContent(_ scrollView: UIScrollView) -> Bool {
            if isPaginated {
                return scrollView.contentSize.width > scrollView.bounds.width + 1
            }
            return scrollView.contentSize.height > scrollView.bounds.height + 1
        }

        private func applyPaginationStyle() {
            guard let webView else { return }
            configureScrollView(webView.scrollView)
            let enabled = isPaginated ? "true" : "false"
            let script = """
            (function() {
              var root = document.documentElement;
              root.setAttribute('data-amgi-note-pagination', '\(enabled)');
              var style = document.getElementById('__amgi_note_pagination_style');
              if (!style) {
                style = document.createElement('style');
                style.id = '__amgi_note_pagination_style';
                (document.head || root).appendChild(style);
              }
              style.textContent = `
                html[data-amgi-note-pagination="true"] {
                  height: 100vh !important;
                  column-width: 50vw !important;
                  -webkit-column-width: 50vw !important;
                  column-fill: auto !important;
                  column-gap: 0 !important;
                  overflow-x: auto !important;
                  overflow-y: hidden !important;
                  scroll-snap-type: x mandatory !important;
                }
                html[data-amgi-note-pagination="true"] body { max-width: none !important; }
              `;
              if (typeof window.__amgiRelayout === 'function') window.__amgiRelayout();
            })();
            """
            webView.evaluateJavaScript(script)
        }

        private func paginate(_ scrollView: UIScrollView, direction: ReaderPageDirection) {
            let viewport = max(1, scrollView.bounds.width)
            let current = Int(round(scrollView.contentOffset.x / viewport))
            let count = max(1, Int(ceil(scrollView.contentSize.width / viewport)))
            let requested = current + (direction == .forward ? 1 : -1)
            let target = max(0, min(requested, count - 1))
            if target == current {
                onPageBoundary(direction)
                return
            }
            scrollView.setContentOffset(
                CGPoint(x: CGFloat(target) * viewport, y: 0),
                animated: true
            )
            lastReportedPageIndex = target
            onPageInfo(target, count)
            let fraction = count > 1 ? Double(target) / Double(count - 1) : 1
            progress = fraction
        }

        private func emitPageInfo(_ scrollView: UIScrollView) {
            let viewport = max(1, scrollView.bounds.width)
            let index = Int(round(scrollView.contentOffset.x / viewport))
            guard index != lastReportedPageIndex else { return }
            lastReportedPageIndex = index
            let count = max(1, Int(ceil(scrollView.contentSize.width / viewport)))
            onPageInfo(index, count)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishLoad = true
            applyPaginationStyle()
            applyPendingInitialProgressIfLoaded()
            consumePageTurnRequestIfNeeded()
        }

        /// Restore prior scroll position once the page reports a real
        /// content size; without this the scrollView height is still
        /// the initial frame size and our offset would be clamped.
        /// One-shot per HTML load — the flag stops later view updates
        /// from yanking the user back to the saved position.
        func applyPendingInitialProgressIfLoaded() {
            guard didFinishLoad, !didApplyInitialProgress,
                  let target = pendingInitialProgress else { return }
            didApplyInitialProgress = true
            pendingInitialProgress = nil
            guard target > 0, let scrollView = webView?.scrollView else { return }

            // Observe contentSize rather than sleeping 50ms and hoping. On a
            // slow device or a long chapter the old delay fired while
            // contentSize was still the initial frame height, so the offset
            // clamped to ~0 and the reader silently reopened at the top.
            if hasScrollableContent(scrollView) {
                Self.applyProgress(target, to: scrollView, isPaginated: isPaginated)
                return
            }
            // `change.newValue` is a CGSize, so nothing main-actor-isolated
            // is captured by the Sendable observation closure; the scroll
            // view is re-resolved inside the isolated block. contentSize is
            // mutated on the main thread, so assumeIsolated holds.
            contentSizeObservation = scrollView.observe(
                \.contentSize, options: [.new]
            ) { [weak self] _, change in
                guard change.newValue != nil else { return }
                MainActor.assumeIsolated {
                    guard let self, let scrollView = self.webView?.scrollView,
                          self.hasScrollableContent(scrollView) else { return }
                    Self.applyProgress(target, to: scrollView, isPaginated: self.isPaginated)
                    self.contentSizeObservation = nil
                }
            }
        }

        private static func applyProgress(
            _ target: Double,
            to scrollView: UIScrollView,
            isPaginated: Bool
        ) {
            if isPaginated {
                let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                scrollView.contentOffset.x = maxOffset * CGFloat(target)
            } else {
                let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                scrollView.contentOffset.y = maxOffset * CGFloat(target)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let usable = isPaginated
                ? scrollView.contentSize.width - scrollView.bounds.width
                : scrollView.contentSize.height - scrollView.bounds.height
            guard usable > 1 else {
                progress = isPaginated ? 1 : 0
                return
            }
            let offset = isPaginated ? scrollView.contentOffset.x : scrollView.contentOffset.y
            let fraction = min(max(offset / usable, 0), 1)
            progress = Double(fraction)
            if isPaginated { emitPageInfo(scrollView) }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "amgiLookup",
                  let phrase = message.body as? String,
                  !phrase.isEmpty else { return }
            onTapLookup?(phrase)
        }
    }
}

extension ChapterWebView.Coordinator {
    func fetchSelection() {
        guard let webView, let onSelectionForNote else { return }
        // window.getSelection() — current text selection in the page.
        // Empty string when nothing's selected; we just no-op then.
        webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSelectionForNote(trimmed)
        }
    }
}
#endif

#if os(macOS)
import AmgiReader
import AmgiTheme
import AmgiAppCore
import Sharing
import SwiftUI
import WebKit

struct ChapterWebView: NSViewRepresentable {
    let html: String
    let initialProgress: Double?
    @Binding var progress: Double
    let isPaginated: Bool
    let pageTurnRequest: ReaderPageTurnRequest?
    let onPageInfo: (Int, Int) -> Void
    let onPageBoundary: (ReaderPageDirection) -> Void
    let onTapLookup: ((String) -> Void)?
    let onSelectionForNote: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            progress: $progress,
            isPaginated: isPaginated,
            onPageInfo: onPageInfo,
            onPageBoundary: onPageBoundary,
            onTapLookup: onTapLookup,
            onSelectionForNote: onSelectionForNote
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "amgiScroll")
        userContent.addUserScript(WKUserScript(
            source: Self.scrollScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        if onTapLookup != nil {
            userContent.add(context.coordinator, name: "amgiLookup")
            userContent.addUserScript(WKUserScript(
                source: Self.tapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(webView: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingInitialProgress = initialProgress
        context.coordinator.pageTurnRequest = pageTurnRequest
        context.coordinator.updatePagination(isPaginated)
        context.coordinator.consumePageTurnRequestIfNeeded()
        guard !html.isEmpty else { return }
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            context.coordinator.didFinishLoad = false
            context.coordinator.didApplyInitialProgress = false
            context.coordinator.lastReportedPageIndex = -1
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            context.coordinator.applyPendingInitialProgressIfLoaded()
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private static let scrollScript = """
        window.addEventListener('scroll', function() {
          const root = document.documentElement;
          const paged = root.getAttribute('data-amgi-note-pagination') === 'true';
          const usable = paged
            ? root.scrollWidth - window.innerWidth
            : root.scrollHeight - window.innerHeight;
          const offset = paged ? root.scrollLeft : window.scrollY;
          const fraction = usable > 1 ? Math.min(Math.max(offset / usable, 0), 1) : (paged ? 1 : 0);
          window.webkit.messageHandlers.amgiScroll.postMessage(fraction);
        }, {passive: true});
        """

    private static let tapScript = """
        document.addEventListener('click', function(e) {
          const sel = window.getSelection();
          if (sel && sel.toString().length > 0) { return; }
          const range = document.caretRangeFromPoint(e.clientX, e.clientY);
          if (!range) { return; }
          let phrase = '';
          let node = range.startContainer;
          let offset = range.startOffset;
          while (node && phrase.length < 96) {
            if (node.nodeType === Node.TEXT_NODE) {
              const t = node.nodeValue || '';
              phrase += t.substring(offset);
              offset = 0;
            }
            if (node.firstChild) {
              node = node.firstChild;
            } else {
              while (node && !node.nextSibling) { node = node.parentNode; }
              node = node && node.nextSibling;
            }
          }
          phrase = phrase.replace(/\\s+/g, ' ').trim();
          if (phrase.length === 0) { return; }
          if (typeof Intl !== 'undefined' && Intl.Segmenter) {
            try {
              const seg = new Intl.Segmenter('und', { granularity: 'sentence' });
              const first = seg.segment(phrase)[Symbol.iterator]().next();
              if (first.value && first.value.segment) {
                phrase = first.value.segment.trim();
              }
            } catch (err) {}
          }
          if (phrase.length > 0) {
            window.webkit.messageHandlers.amgiLookup.postMessage(phrase);
          }
        }, true);
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var pendingInitialProgress: Double?
        var loadedHTML: String?
        var didFinishLoad = false
        var didApplyInitialProgress = false
        var isPaginated: Bool
        var pageTurnRequest: ReaderPageTurnRequest?
        var handledPageTurnSequence = 0
        fileprivate var lastReportedPageIndex = -1
        @Binding var progress: Double
        let onPageInfo: (Int, Int) -> Void
        let onPageBoundary: (ReaderPageDirection) -> Void
        let onTapLookup: ((String) -> Void)?
        let onSelectionForNote: ((String) -> Void)?
        private weak var webView: WKWebView?
        private var selectionObserver: (any NSObjectProtocol)?

        init(
            progress: Binding<Double>,
            isPaginated: Bool,
            onPageInfo: @escaping (Int, Int) -> Void,
            onPageBoundary: @escaping (ReaderPageDirection) -> Void,
            onTapLookup: ((String) -> Void)?,
            onSelectionForNote: ((String) -> Void)?
        ) {
            self._progress = progress
            self.isPaginated = isPaginated
            self.onPageInfo = onPageInfo
            self.onPageBoundary = onPageBoundary
            self.onTapLookup = onTapLookup
            self.onSelectionForNote = onSelectionForNote
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            configureScrollView(webView)
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .amgiReaderRequestSelection,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetchSelection() }
            }
        }

        func detach() {
            if let observer = selectionObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            selectionObserver = nil
            webView = nil
        }

        func updatePagination(_ enabled: Bool) {
            guard isPaginated != enabled else { return }
            isPaginated = enabled
            if let webView { configureScrollView(webView) }
            if didFinishLoad { applyPaginationStyle() }
        }

        func consumePageTurnRequestIfNeeded() {
            guard isPaginated,
                  didFinishLoad,
                  let request = pageTurnRequest,
                  request.sequence > handledPageTurnSequence else { return }
            handledPageTurnSequence = request.sequence
            paginate(request.direction)
        }

        private func configureScrollView(_ webView: WKWebView) {
            // macOS WKWebView does not expose its NSScrollView. The injected
            // CSS owns the spread container; keep this hook as a no-op so the
            // platform coordinators share the same lifecycle.
        }

        private func applyPaginationStyle() {
            guard let webView else { return }
            configureScrollView(webView)
            let enabled = isPaginated ? "true" : "false"
            let script = """
            (function() {
              var root = document.documentElement;
              root.setAttribute('data-amgi-note-pagination', '\(enabled)');
              var style = document.getElementById('__amgi_note_pagination_style');
              if (!style) {
                style = document.createElement('style');
                style.id = '__amgi_note_pagination_style';
                (document.head || root).appendChild(style);
              }
              style.textContent = `
                html[data-amgi-note-pagination="true"] {
                  height: 100vh !important;
                  column-width: 50vw !important;
                  -webkit-column-width: 50vw !important;
                  column-fill: auto !important;
                  column-gap: 0 !important;
                  overflow-x: auto !important;
                  overflow-y: hidden !important;
                  scroll-snap-type: x mandatory !important;
                }
                html[data-amgi-note-pagination="true"] body { max-width: none !important; }
              `;
              if (!\(isPaginated ? "true" : "false")) {
                root.scrollLeft = 0;
                window.scrollTo(0, 0);
              }
            })();
            """
            webView.evaluateJavaScript(script)
        }

        private func paginate(_ direction: ReaderPageDirection) {
            guard let webView else { return }
            let directionOffset = direction == .forward ? 1 : -1
            let script = """
            (function() {
              var root = document.documentElement;
              var width = window.innerWidth || root.clientWidth || 1;
              var count = Math.max(1, Math.ceil((root.scrollWidth || width) / width));
              var current = Math.round(root.scrollLeft / width);
              var target = Math.max(0, Math.min(count - 1, current + \(directionOffset)));
              root.scrollLeft = target * width;
              var fraction = count > 1 ? target / (count - 1) : 1;
              return [current, target, count, fraction].join('|');
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self,
                      let payload = result as? String else { return }
                let values = payload.split(separator: "|").compactMap { Double($0) }
                guard values.count == 4 else { return }
                let current = Int(values[0])
                let target = Int(values[1])
                let count = Int(values[2])
                if current == target {
                    self.onPageBoundary(direction)
                } else {
                    self.onPageInfo(target, count)
                    self.progress = min(max(values[3], 0), 1)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishLoad = true
            applyPaginationStyle()
            applyPendingInitialProgressIfLoaded()
            consumePageTurnRequestIfNeeded()
        }

        func applyPendingInitialProgressIfLoaded() {
            guard didFinishLoad, !didApplyInitialProgress,
                  let target = pendingInitialProgress else { return }
            didApplyInitialProgress = true
            pendingInitialProgress = nil
            guard target > 0, let webView else { return }
            if isPaginated {
                webView.evaluateJavaScript(
                    "document.documentElement.scrollLeft = (document.documentElement.scrollWidth - window.innerWidth) * \(target);"
                )
            } else {
                webView.evaluateJavaScript(
                    "window.scrollTo(0, (document.documentElement.scrollHeight - window.innerHeight) * \(target));"
                )
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "amgiScroll", let value = message.body as? Double {
                progress = min(max(value, 0), 1)
                return
            }
            guard message.name == "amgiLookup",
                  let phrase = message.body as? String,
                  !phrase.isEmpty else { return }
            onTapLookup?(phrase)
        }

        func fetchSelection() {
            guard let webView, let onSelectionForNote else { return }
            webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
                guard let text = result as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onSelectionForNote(trimmed)
            }
        }
    }
}
#endif
