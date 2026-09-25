#if os(macOS)

import AmgiReader
import AppKit
import SwiftUI
import WebKit

/// macOS counterpart of the iOS `UIPageViewController` host. Same public
/// API, different engine: a single WKWebView shows the current chapter and
/// page turns are driven through the bundled injection JS
/// (`__amgiScrollToPage` / `__amgiScrollToFraction`), because macOS WKWebView
/// exposes no UIScrollView to enable native column snapping. Input sources:
/// trackpad/mouse wheel (snap per gesture), edge taps (same 15% zones as
/// iOS), and arrow keys / space via a local event monitor.
struct EPUBPageViewControllerHost: NSViewRepresentable {
    let book: ReaderBook
    /// Resolved content URLs keyed by chapter index. Pre-fetched on the
    /// SwiftUI side (one async call per chapter).
    let chapterContents: [Int: EPUBChapterContent]
    @Binding var chapterIndex: Int
    let styleTokens: EPUBReaderStyleTokens
    /// 0..1 fraction to scroll to on the first chapter load only.
    let pendingRestoreFraction: Double?
    let pageTurnRequest: ReaderPageTurnRequest?
    let selectionRequestID: Int
    /// Suppresses paging while dictionary sheets absorb input (UX spec
    /// edge case), mirroring the iOS host's dataSource suppression.
    let pagingEnabled: Bool

    let onPageInfo: (Int, Int) -> Void
    let onProgress: (Double, Int) -> Void
    let onWordTap: (String, String) -> Void
    let onSelectionForNote: (String) -> Void
    let onTapEmpty: (CGFloat) -> Void
    let onReachedEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(host: self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        context.coordinator.install(in: container)
        context.coordinator.showChapter(
            at: chapterIndex,
            restoreFraction: pendingRestoreFraction
        )
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.host = self
        context.coordinator.applyStyleTokensIfNeeded()
        context.coordinator.consumeSelectionRequestIfNeeded()
        context.coordinator.consumePageTurnRequestIfNeeded()
        if context.coordinator.currentChapterIndex != chapterIndex {
            context.coordinator.showChapter(
                at: chapterIndex,
                restoreFraction: pendingRestoreFraction
            )
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var host: EPUBPageViewControllerHost
        private(set) var currentChapterIndex: Int = -1

        private var webView: EPUBPagingWebView!
        private var didFinishInitialLoad = false
        private var restoreFraction: Double?
        private var pageIndex = 0
        private var pageCount = 1
        private var appliedStyleTokens: EPUBReaderStyleTokens?
        private var keyMonitor: Any?
        private var handledPageTurnSequence = 0
        private var handledSelectionRequestID = 0

        // Wheel gesture state: deltas accumulate until they cross the snap
        // threshold, then latch until the gesture ends. This produces exactly
        // one turn per gesture (including its momentum phase) without a
        // time-based cooldown dead zone.
        private var wheelAccumulator: CGFloat = 0
        private var wheelTurnLatched = false

        init(host: EPUBPageViewControllerHost) {
            self.host = host
            super.init()
        }

        // MARK: Installation

        func install(in container: NSView) {
            let configuration = WKWebViewConfiguration()
            let userContent = WKUserContentController()

            if let css = EPUBReaderBundledResources.css() {
                userContent.addUserScript(WKUserScript(
                    source: EPUBReaderBundledResources.injectStyleSnippet(css: css),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }
            if let js = EPUBReaderBundledResources.interactionJS() {
                userContent.addUserScript(WKUserScript(
                    source: js,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }
            userContent.addUserScript(WKUserScript(
                source: EPUBReaderBundledResources.emptyTapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))

            userContent.add(self, name: "pageInfo")
            userContent.add(self, name: "progress")
            userContent.add(self, name: "wordTap")
            userContent.add(self, name: "emptyTap")
            configuration.userContentController = userContent
            configuration.suppressesIncrementalRendering = false

            let webView = EPUBPagingWebView(frame: .zero, configuration: configuration)
            webView.pagingDelegate = self
            webView.navigationDelegate = self
            // The chapter document paints its own --reader-bg; match the
            // surrounding chrome so no white border flashes during loads.
            webView.underPageBackgroundColor = .windowBackgroundColor

            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])

            self.webView = webView
            applyHostBackgroundColor()
            installKeyMonitor()
            DispatchQueue.main.async { [weak container, weak webView] in
                guard let window = container?.window else { return }
                if window.firstResponder == nil, let webView {
                    window.makeFirstResponder(webView)
                }
            }
        }

        func tearDown() {
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "pageInfo")
            controller.removeScriptMessageHandler(forName: "progress")
            controller.removeScriptMessageHandler(forName: "wordTap")
            controller.removeScriptMessageHandler(forName: "emptyTap")
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        // MARK: Chapter loading

        @discardableResult
        func showChapter(at index: Int, restoreFraction: Double?) -> Bool {
            guard index >= 0, index < host.book.chapters.count else { return false }
            guard let content = host.chapterContents[index] else { return false }
            if host.chapterIndex != index {
                host.chapterIndex = index
            }
            currentChapterIndex = index
            pageIndex = 0
            pageCount = 1
            didFinishInitialLoad = false
            appliedStyleTokens = nil
            wheelAccumulator = 0
            wheelTurnLatched = false
            self.restoreFraction = restoreFraction
            webView.loadFileURL(content.contentURL, allowingReadAccessTo: content.readAccessURL)
            return true
        }

        // MARK: Paging

        enum PageDirection {
            case forward, backward
        }

        @discardableResult
        func paginate(_ direction: PageDirection) -> Bool {
            guard host.pagingEnabled, didFinishInitialLoad else { return false }
            let nextIndex = direction == .forward ? pageIndex + 1 : pageIndex - 1
            let clamped = max(0, min(nextIndex, pageCount - 1))
            if clamped != pageIndex {
                pageIndex = clamped
                webView.evaluateJavaScript(
                    "window.__amgiScrollToPage && window.__amgiScrollToPage(\(clamped));",
                    completionHandler: nil
                )
                // Emit immediately for snappy chrome updates; the debounced JS
                // `pageInfo` message reconfirms once the scroll settles.
                host.onPageInfo(pageIndex, pageCount)
                host.onProgress(progressFraction, pageIndex)
                return true
            }

            switch direction {
            case .forward:
                let nextChapter = currentChapterIndex + 1
                if showChapter(at: nextChapter, restoreFraction: 0) {
                    host.onPageInfo(0, 1)
                    return true
                }
                host.onReachedEnd()
            case .backward:
                // Entering the previous chapter at its end is the page-turn
                // equivalent of moving backwards one page, rather than the
                // surprising jump back to that chapter's title page.
                _ = showChapter(at: currentChapterIndex - 1, restoreFraction: 1)
            }
            return false
        }

        private var progressFraction: Double {
            guard pageCount > 1 else { return 1 }
            return min(1, max(0, Double(pageIndex) / Double(pageCount - 1)))
        }

        /// Wheel input snapped to whole pages. The WebView's own scrolling
        /// is suppressed (we own `scrollLeft` through the injection JS), so
        /// every wheel gesture lands here instead.
        func webViewDidScroll(_ event: NSEvent) {
            guard host.pagingEnabled,
                  didFinishInitialLoad,
                  !event.modifierFlags.contains(.control) else { return }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // Dominant axis; vertical flicks page like horizontal ones.
            let delta = abs(dx) >= abs(dy) ? dx : dy
            guard delta != 0 else { return }

            switch event.phase {
            case .began:
                wheelAccumulator = 0
                wheelTurnLatched = false
            case .ended, .cancelled:
                wheelAccumulator = 0
                wheelTurnLatched = false
                return
            default:
                break
            }
            guard !wheelTurnLatched else { return }

            wheelAccumulator += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 60
            guard abs(wheelAccumulator) >= threshold else { return }
            // Natural scrolling: swipe left / push up (negative delta) moves
            // the content forward. Latch after the call because crossing a
            // chapter deliberately resets gesture state for the new load.
            paginate(delta < 0 ? .forward : .backward)
            wheelTurnLatched = true
        }

        /// Edge-tap zones mirror the iOS coordinator: the outer 15% drive
        //  paging/chapter hops, the centre toggles chrome.
        func handleTap(atRelativeX relativeX: CGFloat) {
            let leftEdge: CGFloat = 0.15
            let rightEdge: CGFloat = 0.85
            if relativeX <= leftEdge {
                if pageIndex == 0 && currentChapterIndex == 0 { return }
                paginate(.backward)
            } else if relativeX >= rightEdge {
                paginate(.forward)
            } else {
                host.onTapEmpty(relativeX)
            }
        }

        private func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      let window = self.webView?.window,
                      NSApp.keyWindow === window,
                      self.host.pagingEnabled else { return event }

                // Key repeat and shortcuts belong to the focused WebView /
                // system. Intercepting them turns holding a key into runaway
                // paging and steals commands such as Space in a search field.
                if event.isARepeat { return event }
                let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                guard event.modifierFlags.intersection(commandModifiers).isEmpty else { return event }
                if let firstResponder = window.firstResponder,
                   firstResponder is NSTextView || firstResponder is NSTextField {
                    return event
                }

                switch event.keyCode {
                case 123, 116: // left arrow, page up
                    return self.paginate(.backward) ? nil : event
                case 124, 121: // right arrow, page down
                    return self.paginate(.forward) ? nil : event
                case 49: // space
                    return self.paginate(.forward) ? nil : event
                default:
                    return event
                }
            }
        }

        func consumePageTurnRequestIfNeeded() {
            guard let request = host.pageTurnRequest,
                  request.sequence > handledPageTurnSequence,
                  didFinishInitialLoad else { return }
            handledPageTurnSequence = request.sequence
            paginate(request.direction == .forward ? .forward : .backward)
        }

        func consumeSelectionRequestIfNeeded() {
            guard host.selectionRequestID > handledSelectionRequestID else { return }
            handledSelectionRequestID = host.selectionRequestID
            webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
                guard let text = result as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.host.onSelectionForNote(trimmed)
            }
        }

        // MARK: Style tokens + background

        func applyStyleTokensIfNeeded() {
            guard appliedStyleTokens != host.styleTokens else { return }
            applyStyleTokens()
        }

        func applyStyleTokens() {
            guard didFinishInitialLoad else { return }
            appliedStyleTokens = host.styleTokens
            let tokens = host.styleTokens
            let mode = tokens.verticalMode ? "vertical-rl" : "horizontal-tb"
            let escapedFontFamily = tokens.fontFamilyCSS
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
              var r = document.documentElement;
              r.style.setProperty('--reader-fg', '\(tokens.foreground)');
              r.style.setProperty('--reader-bg', '\(tokens.background)');
              r.style.setProperty('--reader-font-size', '\(tokens.fontSizePx)px');
              r.style.setProperty('--reader-line-height', '\(tokens.lineHeight)');
              r.style.setProperty('--reader-padding', '\(tokens.paddingPx)px');
              r.style.setProperty('--reader-page-margin', '\(tokens.pageMarginPx)px');
              r.style.setProperty('--reader-page-padding', '\(tokens.paddingPx)px');
              r.style.setProperty('--reader-writing-mode', '\(mode)');
              r.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
              r.style.setProperty('--reader-text-align', '\(tokens.textAlign)');
              r.style.setProperty('--reader-tok-underline', '\(tokens.tokenUnderlineCSS)');
              r.setAttribute('data-amgi-page-columns', '\(tokens.pageColumns == 2 ? 2 : 1)');
              if (typeof window.__amgiRelayout === 'function') { window.__amgiRelayout(); }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            applyHostBackgroundColor()
        }

        private func applyHostBackgroundColor() {
            let color = NSColor.color(fromHex: host.styleTokens.background) ?? NSColor.windowBackgroundColor
            webView.underPageBackgroundColor = color
            webView.superview?.layer?.backgroundColor = color.cgColor
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishInitialLoad = true
            applyStyleTokens()
            consumePageTurnRequestIfNeeded()
            if let fraction = restoreFraction {
                restoreFraction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.webView.evaluateJavaScript(
                        "window.__amgiScrollToFraction && window.__amgiScrollToFraction(\(fraction));",
                        completionHandler: nil
                    )
                }
            }
        }

        // MARK: WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WebKit delivers script messages on the main thread; message.name /
            // .body are @MainActor. assumeIsolated reads them and dispatches
            // synchronously — no Task hop needed. (Same pattern as the iOS bridge.)
            MainActor.assumeIsolated {
                self.handle(name: message.name, body: message.body)
            }
        }

        private func handle(name: String, body: Any) {
            switch name {
            case "pageInfo":
                guard let dict = body as? [String: Any],
                      let newPageIndex = dict["pageIndex"] as? Int,
                      let newPageCount = dict["pageCount"] as? Int else { return }
                pageIndex = newPageIndex
                pageCount = max(1, newPageCount)
                host.onPageInfo(pageIndex, pageCount)
            case "progress":
                guard let dict = body as? [String: Any],
                      let newPageIndex = dict["pageIndex"] as? Int,
                      let fraction = dict["progressFraction"] as? Double else { return }
                host.onProgress(pageCount <= 1 ? 1 : fraction, newPageIndex)
            case "wordTap":
                guard let dict = body as? [String: Any] else { return }
                let token = (dict["token"] as? String) ?? ""
                let sentence = (dict["sentence"] as? String) ?? token
                guard !token.isEmpty else { return }
                host.onWordTap(token, sentence)
            case "emptyTap":
                guard let number = body as? NSNumber else { return }
                handleTap(atRelativeX: CGFloat(truncating: number))
            default:
                break
            }
        }
    }
}

// MARK: - Scroll-capturing WebView

/// WKWebView that routes wheel events to the paging coordinator instead of
/// letting WebKit free-scroll: page turns snap column-by-column through the
/// injection JS.
private final class EPUBPagingWebView: WKWebView {
    @MainActor weak var pagingDelegate: (any EPUBPagingWebViewDelegate)?

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.scrollWheel(with: event)
        } else {
            pagingDelegate?.webViewDidScroll(event)
        }
    }
}

@MainActor
private protocol EPUBPagingWebViewDelegate: AnyObject {
    func webViewDidScroll(_ event: NSEvent)
}

extension EPUBPageViewControllerHost.Coordinator: EPUBPagingWebViewDelegate {}

// MARK: - Hex → NSColor

private extension NSColor {
    /// Parse "#RRGGBB" or "#RRGGBBAA" (case-insensitive) into an NSColor.
    /// Returns nil for malformed input — caller falls back to a system
    /// colour to avoid a white flash.
    static func color(fromHex hex: String) -> NSColor? {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard let value = UInt64(trimmed, radix: 16) else { return nil }
        switch trimmed.count {
        case 6:
            let r = CGFloat((value & 0xFF0000) >> 16) / 255
            let g = CGFloat((value & 0x00FF00) >> 8) / 255
            let b = CGFloat((value & 0x0000FF) / 255)
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = CGFloat((value & 0xFF000000) >> 24) / 255
            let g = CGFloat((value & 0x00FF0000) >> 16) / 255
            let b = CGFloat((value & 0x0000FF00) >> 8) / 255
            let a = CGFloat(value & 0x000000FF) / 255
            return NSColor(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }
}

#endif
