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
    /// Suppresses paging while dictionary sheets absorb input (UX spec
    /// edge case), mirroring the iOS host's dataSource suppression.
    let pagingEnabled: Bool

    let onPageInfo: (Int, Int) -> Void
    let onProgress: (Double, Int) -> Void
    let onWordTap: (String, String) -> Void
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

        // Wheel gesture state: deltas accumulate until they cross the snap
        // threshold, producing at most one page turn per gesture burst.
        private var wheelAccumulator: CGFloat = 0
        private var wheelCooldownUntil = Date.distantPast

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
            if let js = EPUBReaderBundledResources.js() {
                userContent.addUserScript(WKUserScript(
                    source: js,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }

            userContent.add(self, name: "pageInfo")
            userContent.add(self, name: "progress")
            userContent.add(self, name: "wordTap")
            configuration.userContentController = userContent
            configuration.suppressesIncrementalRendering = false

            let webView = EPUBPagingWebView(frame: .zero, configuration: configuration)
            webView.pagingDelegate = self
            webView.navigationDelegate = self
            // The chapter document paints its own --reader-bg; match the
            // surrounding chrome so no white border flashes during loads.
            webView.underPageBackgroundColor = .windowBackgroundColor

            let click = NSClickGestureRecognizer(
                target: self,
                action: #selector(handleClick(_:))
            )
            webView.addGestureRecognizer(click)

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
        }

        func tearDown() {
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "pageInfo")
            controller.removeScriptMessageHandler(forName: "progress")
            controller.removeScriptMessageHandler(forName: "wordTap")
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        // MARK: Chapter loading

        func showChapter(at index: Int, restoreFraction: Double?) {
            guard index >= 0, index < host.book.chapters.count else { return }
            guard let content = host.chapterContents[index] else { return }
            currentChapterIndex = index
            pageIndex = 0
            pageCount = 1
            didFinishInitialLoad = false
            self.restoreFraction = restoreFraction
            webView.loadFileURL(content.contentURL, allowingReadAccessTo: content.readAccessURL)
        }

        // MARK: Paging

        enum PageDirection {
            case forward, backward
        }

        func paginate(_ direction: PageDirection) {
            guard host.pagingEnabled, didFinishInitialLoad else { return }
            let nextIndex = direction == .forward ? pageIndex + 1 : pageIndex - 1
            let clamped = max(0, min(nextIndex, pageCount - 1))
            guard clamped != pageIndex else { return }
            pageIndex = clamped
            webView.evaluateJavaScript(
                "window.__amgiScrollToPage && window.__amgiScrollToPage(\(clamped));",
                completionHandler: nil
            )
            // Emit immediately for snappy chrome updates; the debounced JS
            // `pageInfo` message reconfirms once the scroll settles.
            host.onPageInfo(pageIndex, pageCount)
            host.onProgress(progressFraction, pageIndex)
        }

        private var progressFraction: Double {
            let denom = Double(max(1, pageCount - 1))
            return min(1, max(0, Double(pageIndex) / denom))
        }

        /// Wheel input snapped to whole pages. The WebView's own scrolling
        /// is suppressed (we own `scrollLeft` through the injection JS), so
        /// every wheel gesture lands here instead.
        func webViewDidScroll(_ event: NSEvent) {
            guard host.pagingEnabled, didFinishInitialLoad else { return }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // Dominant axis; vertical flicks page like horizontal ones.
            let delta = abs(dx) >= abs(dy) ? dx : dy
            guard delta != 0 else { return }

            switch event.phase {
            case .began:
                wheelAccumulator = 0
            case .ended, .cancelled:
                wheelAccumulator = 0
            default:
                break
            }

            wheelAccumulator += delta
            let now = Date()
            guard abs(wheelAccumulator) >= 60, now >= wheelCooldownUntil else { return }
            wheelAccumulator = 0
            wheelCooldownUntil = now.addingTimeInterval(0.25)

            // Natural scrolling: swipe left / push up (negative delta) moves
            // the content forward.
            paginate(delta < 0 ? .forward : .backward)
        }

        /// Edge-tap zones mirror the iOS coordinator: the outer 15% drive
        //  paging/chapter hops, the centre toggles chrome.
        func handleTap(atRelativeX relativeX: CGFloat) {
            let leftEdge: CGFloat = 0.15
            let rightEdge: CGFloat = 0.85
            if relativeX <= leftEdge {
                if pageIndex == 0 && currentChapterIndex == 0 {
                    host.onTapEmpty(relativeX)
                    return
                }
                if pageIndex == 0 {
                    host.chapterIndex = currentChapterIndex - 1
                } else {
                    paginate(.backward)
                }
            } else if relativeX >= rightEdge {
                if pageIndex >= pageCount - 1 && currentChapterIndex == host.book.chapters.count - 1 {
                    host.onReachedEnd()
                    return
                }
                if pageIndex >= pageCount - 1 {
                    host.chapterIndex = currentChapterIndex + 1
                } else {
                    paginate(.forward)
                }
            } else {
                host.onTapEmpty(relativeX)
            }
        }

        @objc
        private func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let relativeX = view.bounds.width > 0 ? location.x / view.bounds.width : 0.5
            handleTap(atRelativeX: relativeX)
        }

        private func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      let window = self.webView?.window,
                      NSApp.keyWindow === window,
                      self.host.pagingEnabled
                else { return event }
                switch event.keyCode {
                case 123: // left arrow
                    self.paginate(.backward)
                    return nil
                case 124: // right arrow
                    self.paginate(.forward)
                    return nil
                case 49: // space
                    self.paginate(.forward)
                    return nil
                default:
                    return event
                }
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
                host.onProgress(fraction, newPageIndex)
            case "wordTap":
                guard let dict = body as? [String: Any] else { return }
                let token = (dict["token"] as? String) ?? ""
                let sentence = (dict["sentence"] as? String) ?? token
                guard !token.isEmpty else { return }
                host.onWordTap(token, sentence)
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
    @MainActor weak var pagingDelegate: EPUBPagingWebViewDelegate?

    override func scrollWheel(with event: NSEvent) {
        pagingDelegate?.webViewDidScroll(event)
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
