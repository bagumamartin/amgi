#if os(macOS)

import AmgiReader
import AppKit
import SwiftUI
import WebKit
import AmgiTheme

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
    /// `anchor` is nil when the page could not produce one (an older injected
    /// script, or a tap that did not land on a tokenised span).
    let onWordTap: (String, String, ReaderSourceAnchor?) -> Void
    let onSelectionForNote: (String) -> Void
    let onTapEmpty: (CGFloat) -> Void
    let onReachedEnd: () -> Void
    /// A highlight or bookmark created from the selection menu. Separate from
    /// `onSelectionForNote` because these are local marks, not lookups.
    var onSelectionMark: ((ReaderAnnotation.Kind, ReaderSourceAnchor?, String) -> Void)?
    /// Page-turn effect. macOS has no `UIPageViewController` to style, so the
    /// host applies this itself when it swaps chapters; Curl has no macOS
    /// equivalent and falls back to a crossfade.
    let pageTransition: ReaderPageTransition
    /// Running total of rendered pages per chapter, so page numbers can be
    /// book-wide rather than chapter-relative.
    var paginationIndex: ReaderPaginationIndex?
    /// Book title, printed as the running head on every page.
    let runningHead: String
    /// Bridge to the live web view, for anchor capture and marks. Same
    /// contract and same parameter order as the iOS host, so the SwiftUI call
    /// site stays platform-agnostic.
    /// Declared last so both hosts share one parameter order.
    let commands: ReaderPageCommands

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
        context.coordinator.fulfilPendingAnchorRequest()
        context.coordinator.fulfilSelectionMarkRequest()
        context.coordinator.presentSelectionMenuIfNeeded()
        context.coordinator.consumePageTurnRequestIfNeeded()
        if context.coordinator.currentChapterIndex != chapterIndex {
            context.coordinator.showChapter(
                at: chapterIndex,
                restoreFraction: pendingRestoreFraction
            )
        }
        if context.coordinator.consumeMarksRefresh() {
            context.coordinator.applyPendingMarks()
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
            // `dataDetectorTypes` is a *view* property on macOS (and a
            // configuration property on iOS). Set on the view below.
            let userContent = WKUserContentController()

            // First script: the CSP has to be in place before the book parses.
            userContent.addUserScript(WKUserScript(
                source: EPUBReaderBundledResources.contentSecurityPolicyScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
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
            guard index >= 0, index < host.book.chapters.count,
                  host.chapterContents[index] != nil else { return false }
            // The first chapter is not a *transition* — there is nothing to
            // come from — so it must not fade in from transparent on open.
            let isInitialLoad = currentContent == nil
            guard !isInitialLoad else {
                return loadChapter(index: index, restoreFraction: restoreFraction)
            }
            return transitionForChapterChange(to: index, restoreFraction: restoreFraction) { [weak self] in
                self?.loadChapter(index: index, restoreFraction: restoreFraction) ?? false
            }
        }

        /// The chapter switch itself, with no animation. Split out of
        /// `showChapter` so the transition wrapper can call exactly this.
        @discardableResult
        private func loadChapter(index: Int, restoreFraction: Double?) -> Bool {
            guard index >= 0, index < host.book.chapters.count,
                  let content = host.chapterContents[index] else { return false }
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
            currentReadAccessURL = content.readAccessURL
            currentContent = content
            webView.loadFileURL(content.contentURL, allowingReadAccessTo: content.readAccessURL)
            return true
        }

        /// Root the currently-loaded chapter may read from. `nil` before the
        /// first chapter loads, which the policy treats as "deny every
        /// `file:` URL" — the fail-closed default.
        private var currentReadAccessURL: URL?
        /// Identity of the chapter on screen, used to stamp source anchors.
        private var currentContent: EPUBChapterContent?
        /// The most recent selection, awaiting a choice from the contextual
        /// menu. Cleared as soon as the menu is dismissed.
        private var pendingSelection: ReaderSelectionPayload?

        // MARK: Page transition

        /// Fades the web view out and back in around a chapter load.
        ///
        /// A chapter change is a full document load, so the browser paints
        /// white first regardless of what we animate. Fading out *before* the
        /// load covers that flash; fading back in after hides the fact that
        /// anything happened at all. This is how "Fast Fade" is achieved
        /// without a second web view.
        private func transitionForChapterChange(
            to index: Int,
            restoreFraction: Double?,
            run: @escaping @MainActor () -> Bool
        ) -> Bool {
            let style = host.pageTransition
            // Reduce Motion means the user has asked for no animation; honour
            // that before anything else, including Curl.
            guard !AmgiMotion.prefersReducedMotion, style != .scroll, webView != nil else {
                return run()
            }
            let duration = min(0.18, style.duration)
            fadeOut(duration: duration) { [weak self] in
                guard let self else { return }
                _ = run()
                fadeIn(duration: duration)
                _ = index
                _ = restoreFraction
            }
            return true
        }

        private func fadeOut(duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.allowsImplicitAnimation = true
                self.webView?.animator().alphaValue = 0
            } completionHandler: {
                // The completion handler is not main-actor isolated, and
                // `webView` is, so hop back explicitly.
                Task { @MainActor in completion() }
            }
        }

        private func fadeIn(duration: TimeInterval) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.allowsImplicitAnimation = true
                self.webView?.animator().alphaValue = 1
            }
        }

        // MARK: Commands

        /// Whether the view asked for the chapter's marks to be repainted.
        /// One-shot, so it does not re-run on every SwiftUI update.
        func consumeMarksRefresh() -> Bool {
            guard host.commands.marksRefresh != nil else { return false }
            host.commands.marksRefresh = nil
            return true
        }

        /// Re-apply the marks the view last computed.
        func applyPendingMarks() {
            guard let webView, !host.commands.lastAppliedMarks.isEmpty else { return }
            let json: String
            if let data = try? JSONSerialization.data(
                withJSONObject: host.commands.lastAppliedMarks
            ), let text = String(data: data, encoding: .utf8) {
                json = text
            } else {
                json = "[]"
            }
            webView.evaluateJavaScript(
                "window.__amgiApplyMarks ? window.__amgiApplyMarks(\(json)) : 0;",
                completionHandler: nil
            )
        }

        /// Shows the contextual menu for the current selection.
        ///
        /// macOS builds its own menu for a web view selection; appending ours
        /// keeps the platform's Cut/Copy/Paste/Look Up entries and adds the
        /// reader's actions on top.
        func presentSelectionMenuIfNeeded() {
            guard let payload = pendingSelection else { return }
            let menu = NSMenu()
            for action in ReaderSelectionMenu.actionOrder
            where ReaderSelectionMenu.isAvailable(action, for: payload) {
                let item = NSMenuItem(
                    title: ReaderSelectionMenu.title(for: action),
                    action: #selector(performSelectionAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = action.rawValue
                item.image = NSImage(
                    systemSymbolName: ReaderSelectionMenu.systemImage(for: action),
                    accessibilityDescription: nil
                )
                menu.addItem(item)
            }
            guard !menu.items.isEmpty else {
                pendingSelection = nil
                return
            }
            if let webView {
                // `popUp` runs a nested event loop and returns only once the
                // menu closes, and the chosen action fires *inside* that loop.
                // So the payload must outlive the call — clearing it before
                // would leave the action handler with nothing to act on.
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: webView)
            }
            pendingSelection = nil
        }

        @objc private func performSelectionAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = ReaderSelectionAction(rawValue: raw) else { return }
            // The selection text was captured when the menu was built; the
            // Range is not guaranteed to still exist by the time the item is
            // clicked, so reuse the payload rather than re-reading the page.
            guard let payload = pendingSelection else { return }
            let anchor = payload.anchor ?? pendingAnchor(forSelection: payload.text)
            switch action {
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payload.text, forType: .string)
            case .lookUp, .addNote:
                host.onSelectionForNote(payload.token)
            case .highlight:
                host.commands.requestSelectionMark(
                    .init(kind: .highlight, anchor: anchor, excerpt: payload.text)
                )
            case .bookmark:
                host.commands.requestSelectionMark(
                    .init(kind: .bookmark, anchor: anchor, excerpt: payload.text)
                )
            }
        }

        /// Asks the page for an anchor at the current selection. Falls back to
        /// nil, which stores the mark with a quote-only anchor that still
        /// re-anchors by text search.
        private func pendingAnchor(forSelection selection: String) -> ReaderSourceAnchor? {
            guard let content = currentContent else { return nil }
            let quoted = ReaderSourceAnchor.normalize(selection)
            let json: String
            if let data = try? JSONSerialization.data(
                withJSONObject: ["quote": quoted]
            ), let text = String(data: data, encoding: .utf8) {
                json = text
            } else {
                return nil
            }
            var anchor: ReaderSourceAnchor?
            webView?.evaluateJavaScript(
                "window.__amgiAnchorForQuote ? window.__amgiAnchorForQuote(\(json)) : null;"
            ) { result, _ in
                MainActor.assumeIsolated {
                    anchor = ReaderSourceAnchor(scriptPayload: result)
                }
            }
            guard var resolved = anchor else { return nil }
            resolved.bookID = content.bookID
            resolved.chapterID = content.chapterID
            resolved.chapterHref = content.chapterHref
            return resolved
        }

        /// Hands a mark requested from the selection menu to the view.
        /// One-shot, so a double-fired menu cannot store the mark twice.
        func fulfilSelectionMarkRequest() {
            guard let request = host.commands.selectionMarkRequest else { return }
            host.commands.selectionMarkRequest = nil
            host.onSelectionMark?(request.kind, request.anchor, request.excerpt)
        }

        /// Fulfils a pending anchor request from the view against the chapter
        /// on screen.
        func fulfilPendingAnchorRequest() {
            guard let request = host.commands.anchorRequest else { return }
            guard let webView, let content = currentContent else {
                host.commands.fulfilAnchorRequest(with: nil)
                return
            }
            webView.evaluateJavaScript(
                "window.__amgiCurrentAnchor && window.__amgiCurrentAnchor();"
            ) { result, _ in
                MainActor.assumeIsolated {
                    guard var anchor = ReaderSourceAnchor(scriptPayload: result) else {
                        request(nil)
                        return
                    }
                    anchor.bookID = content.bookID
                    anchor.chapterID = content.chapterID
                    anchor.chapterHref = content.chapterHref
                    request(anchor)
                }
            }
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
                recordPagination()
                refreshPageFurniture()
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

        /// Records what this chapter laid out to, so the reader can be given a
        /// book-wide page number rather than a chapter-relative one.
        private func recordPagination() {
            guard var index = host.paginationIndex else { return }
            index.record(chapter: currentChapterIndex, pageCount: pageCount)
            host.paginationIndex = index
        }

        /// Prints the page number and running head onto the page, in the
        /// book's own face at the page's own margins.
        private func refreshPageFurniture() {
            let payload: [String: Any] = [
                "page": pageIndex + 1,
                "head": host.runningHead,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.__amgiSetPageFurniture && window.__amgiSetPageFurniture(\(json));",
                completionHandler: nil
            )
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
              r.style.setProperty('--reader-press', '\(tokens.pressTintCSS)');
              r.style.setProperty('--reader-inset-top', '\(tokens.insetTopPx)px');
              r.style.setProperty('--reader-inset-bottom', '\(tokens.insetBottomPx)px');
              // Gate the font override on the user having picked a family; an
              // empty stack means "Book", so the book's own face is kept.
              r.setAttribute(
                'data-amgi-honour-book-font',
                '\(tokens.fontFamilyCSS.isEmpty ? "1" : "0")'
              );
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
            // Paint the chapter's annotations as part of the load, not as a
            // follow-up: a mark applied before tokenisation would silently
            // match nothing.
            applyPendingMarks()
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

        // MARK: WKNavigationDelegate

        /// Gate every navigation the book attempts. Without this, a
        /// `<a href>`, a `window.location` assignment, or a book script can
        /// navigate the reader anywhere — including `file://` URLs inside the
        /// read scope we granted the page, or off the device over http(s).
        ///
        /// The `decisionHandler` type must match WebKit's declaration exactly
        /// (`@escaping @MainActor @Sendable`). Plain `@escaping` compiles to a
        /// "nearly matches" *warning* and the method is then never called.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let decision = EPUBNavigationPolicy.decide(
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                readAccessURL: currentReadAccessURL
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .openExternally(let url):
                // An author-placed link is user intent, so hand it to the
                // system rather than loading it in the reader.
                decisionHandler(.cancel)
                EPUBNavigationPolicy.openInSystem(url)
            case .cancel:
                decisionHandler(.cancel)
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
                // A book can author its own <iframe>, and anything inside it
                // shares the page's script world. Only the main frame's own
                // document is trusted to drive the reader.
                guard message.frameInfo.isMainFrame else { return }
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
                recordPagination()
                refreshPageFurniture()
                host.onPageInfo(pageIndex, pageCount)
            case "progress":
                guard let dict = body as? [String: Any],
                      let newPageIndex = dict["pageIndex"] as? Int,
                      let fraction = dict["progressFraction"] as? Double else { return }
                host.onProgress(pageCount <= 1 ? 1 : fraction, newPageIndex)
            case "wordSelection":
                // A long press produced a selection. macOS shows its own
                // contextual menu on a selection; this reports what was
                // selected so the Anki actions can be added to it. A single
                // tap never reaches here.
                guard let dict = body as? [String: Any] else { return }
                let selection = (dict["selection"] as? String) ?? ""
                guard !selection.isEmpty else { return }
                let token = (dict["token"] as? String) ?? selection
                let sentence = (dict["sentence"] as? String) ?? selection
                var anchor = ReaderSourceAnchor(scriptPayload: dict["anchor"])
                if var resolved = anchor, let content = currentContent {
                    resolved.bookID = content.bookID
                    resolved.chapterID = content.chapterID
                    resolved.chapterHref = content.chapterHref
                    anchor = resolved
                } else {
                    anchor = nil
                }
                pendingSelection = ReaderSelectionPayload(
                    text: selection,
                    token: token,
                    sentence: sentence,
                    anchor: anchor
                )
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
