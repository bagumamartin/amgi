import AmgiAppCore
import AmgiAppShared
import OSLog
import SwiftUI
import WebKit
import AVFoundation
import AmgiCardWeb
#if os(iOS)
import UIKit
#else
import AppKit
#endif


struct CardWebView: View {
    @Environment(\.colorScheme) private var colorScheme

    let html: String
    let cardCSS: String
    let autoplayEnabled: Bool
    let isAnswerSide: Bool
    let cardOrdinal: UInt32
    let replayRequestID: Int
    let stopAudioRequestID: Int
    let replayMode: CardWebViewReplayMode
    let showInlineAudioReplayButtons: Bool
    let openLinksExternally: Bool
    let lookupPopupEnabled: Bool
    let prefetchHTML: String?
    let contentAlignment: CardWebViewContentAlignment
    let bottomContentInset: CGFloat
    let onAudioStateChange: ((Bool) -> Void)?
    let onCardBackgroundColorChange: ((PlatformColor, Bool) -> Void)?
    let onLookupRequested: ((String?, String?, CGPoint) -> Void)?

    init(
        html: String,
        cardCSS: String = "",
        autoplayEnabled: Bool = true,
        isAnswerSide: Bool = false,
        cardOrdinal: UInt32 = 0,
        replayRequestID: Int = 0,
        stopAudioRequestID: Int = 0,
        replayMode: CardWebViewReplayMode = .question,
        showInlineAudioReplayButtons: Bool = true,
        openLinksExternally: Bool = true,
        lookupPopupEnabled: Bool = false,
        prefetchHTML: String? = nil,
        contentAlignment: CardWebViewContentAlignment = .center,
        bottomContentInset: CGFloat = 0,
        onAudioStateChange: ((Bool) -> Void)? = nil,
        onCardBackgroundColorChange: ((PlatformColor, Bool) -> Void)? = nil,
        onLookupRequested: ((String?, String?, CGPoint) -> Void)? = nil
    ) {
        self.html = html
        self.cardCSS = cardCSS
        self.autoplayEnabled = autoplayEnabled
        self.isAnswerSide = isAnswerSide
        self.cardOrdinal = cardOrdinal
        self.replayRequestID = replayRequestID
        self.stopAudioRequestID = stopAudioRequestID
        self.replayMode = replayMode
        self.showInlineAudioReplayButtons = showInlineAudioReplayButtons
        self.openLinksExternally = openLinksExternally
        self.lookupPopupEnabled = lookupPopupEnabled
        self.prefetchHTML = prefetchHTML
        self.contentAlignment = contentAlignment
        self.bottomContentInset = bottomContentInset
        self.onAudioStateChange = onAudioStateChange
        self.onCardBackgroundColorChange = onCardBackgroundColorChange
        self.onLookupRequested = onLookupRequested
    }

    var body: some View {
        CardWebViewPlatformHost(card: self)
    }

    func makeCoordinator() -> CardWebViewCoordinator {
        // Adopt the prewarmed pair when available: the returned coordinator
        // already owns a loaded frame page and its webview, so the review's
        // first HTML card skips the WebKit process cold-start entirely.
        // Its nil callbacks are filled by the first `applyUpdate` via
        // `refreshCallbacks`.
        if let prewarmed = CardWebViewPrewarmer.shared.take() {
            return prewarmed
        }
        return CardWebViewCoordinator(
            onAudioStateChange: onAudioStateChange,
            onCardBackgroundColorChange: onCardBackgroundColorChange,
            onLookupRequested: onLookupRequested
        )
    }

    fileprivate func makeConfiguredWebView(coordinator: CardWebViewCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(CardAssetScheme(), forURLScheme: CardAssetPath.scheme)
        config.userContentController.add(coordinator, name: "amgiAudioState")
        config.userContentController.add(coordinator, name: "amgiOpenLink")
        config.userContentController.add(coordinator, name: "amgiSpeakTts")
        config.userContentController.add(coordinator, name: "amgiStopTts")
        config.userContentController.add(coordinator, name: "amgiCardTheme")
        config.userContentController.add(coordinator, name: "amgiLookupText")

        if onLookupRequested != nil {
            config.userContentController.addUserScript(WKUserScript(
                source: Self.tapLookupBootstrapJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        #endif
        webView.navigationDelegate = coordinator
        return webView
    }

    fileprivate static func dismantleConfigured(_ webView: WKWebView, coordinator: CardWebViewCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiAudioState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiOpenLink")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiSpeakTts")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiStopTts")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiCardTheme")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiLookupText")
        coordinator.stopTTS()
    }

    fileprivate func applyUpdate(_ webView: WKWebView, coordinator: CardWebViewCoordinator) {
        let isDarkMode = colorScheme == .dark
        let alignTop = contentAlignment == .top

        // Both signatures are derived from the *inputs*, never from the
        // processed output. `processedHTML` costs three whole-document regex
        // passes, so hashing it to decide whether anything changed meant
        // paying that cost on every render and usually throwing it away.
        // `ReviewContent` reads a dozen `session.*` properties, so an
        // audio-state flip, an undo, or a flag tap each used to run all three.
        // `html`, `isDarkMode`, and `showInlineAudioReplayButtons` are its only
        // inputs, so they discriminate exactly as well.
        let pageSignature = "\(isDarkMode)"
        let contentSignature = "\(autoplayEnabled)|\(isAnswerSide)|\(lookupPopupEnabled)|\(replayMode.rawValue)|\(cardOrdinal)|\(alignTop)|\(showInlineAudioReplayButtons)|\(cardCSS.hashValue)|\(html.hashValue)|\(prefetchHTML?.hashValue ?? 0)"

        // Bookkeeping that has to track every render, expensive or not.
        coordinator.openLinksExternally = openLinksExternally
        // Refresh every update: an adopted prewarm coordinator arrives with
        // nil callbacks and takes over this session's wiring here.
        coordinator.refreshCallbacks(
            onAudioStateChange: onAudioStateChange,
            onCardBackgroundColorChange: onCardBackgroundColorChange,
            onLookupRequested: onLookupRequested,
            onQuestionCanvasTap: nil
        )
        coordinator.currentWebView = webView
        #if os(iOS)
        webView.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
        #else
        webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)
        #endif

        let pageChanged = coordinator.lastPageSignature != pageSignature
        let contentChanged = coordinator.lastContentSignature != contentSignature

        if pageChanged || contentChanged {
            // Convert Anki [sound:filename.mp3] tags to <audio> HTML elements.
            // The Rust renderer keeps these tags literal; the client must expand them.
            let processedHTML = Self.deferCardScripts(in:
                Self.expandTTSTags(
                    in: Self.expandSoundTags(
                        html,
                        isDarkMode: isDarkMode,
                        showReplayButtons: showInlineAudioReplayButtons
                    ),
                    isDarkMode: isDarkMode,
                    showReplayButtons: showInlineAudioReplayButtons
                )
            )
            let bodyPaddingBottom = 16
            let cardPaddingBottom = 0
            let bodyClass = Self.bodyClasses(cardOrdinal: cardOrdinal, isDarkMode: isDarkMode)

            // Build the JS call that shows the card – passed via evaluateJavaScript so
            // HTML content never lives inside a <script> literal in the page source.
            let showCardScript = Self.showCardScript(
                processedHTML: processedHTML,
                prefetchHTML: prefetchHTML,
                cardCSS: cardCSS,
                isAnswerSide: isAnswerSide,
                lookupPopupEnabled: lookupPopupEnabled,
                bodyClass: bodyClass,
                autoplayEnabled: autoplayEnabled,
                replayMode: replayMode.rawValue,
                alignTop: alignTop,
                bodyPaddingBottom: bodyPaddingBottom,
                cardPaddingBottom: cardPaddingBottom
            )
            // Only when the card content actually changes. Unconditionally,
            // any unrelated re-render — including the audio callback writing
            // `isAudioPlaying` back onto the session — cut off speech that was
            // still playing.
            coordinator.stopTTS()

            if pageChanged {
                coordinator.lastPageSignature = pageSignature
                coordinator.lastContentSignature = contentSignature
                coordinator.isPageLoaded = false
                let htmlClass = Self.htmlClasses(isDarkMode: isDarkMode)
                let playIconHTML = Self.audioButtonIconHTML(systemName: "play.circle", alt: "Play", isDarkMode: isDarkMode)
                let pauseIconHTML = Self.audioButtonIconHTML(systemName: "pause.circle", alt: "Pause", isDarkMode: isDarkMode)
                let baseTag = CardAssetPath.mediaBaseTag()
                // Stash the show-card call so we can run it once the page finishes loading.
                coordinator.pendingUpdateScript = showCardScript

                let styledHTML = Self.buildFrameHTML(
                    htmlClass: htmlClass,
                    isDarkMode: isDarkMode,
                    playIconHTML: playIconHTML,
                    pauseIconHTML: pauseIconHTML,
                    baseTag: baseTag
                )

                // Use cardBaseURL so that MathJax, fonts, and other resources load correctly.
                // The CardAssetScheme handler processes amgi-asset:// URLs.
                webView.loadHTMLString(styledHTML, baseURL: CardAssetPath.cardBaseURL)
            } else {
                coordinator.lastContentSignature = contentSignature
                if coordinator.isPageLoaded {
                    webView.evaluateJavaScript(showCardScript) { _, error in
                        // A JS exception in _showQuestion/_showAnswer renders
                        // a blank card; dropping the error left no diagnostic.
                        if let error { Log.review.error("showCard script failed: \(error)") }
                    }
                } else {
                    coordinator.pendingUpdateScript = showCardScript
                }
            }
        }
        if replayRequestID != coordinator.lastReplayRequestID {
            coordinator.lastReplayRequestID = replayRequestID
            webView.evaluateJavaScript("window.amgiReplayAll && window.amgiReplayAll('" + replayMode.rawValue + "');") { _, error in
                if let error { Log.review.error("replayAll script failed: \(error)") }
            }
        }

        if stopAudioRequestID != coordinator.lastStopAudioRequestID {
            coordinator.lastStopAudioRequestID = stopAudioRequestID
            webView.evaluateJavaScript("window.amgiStopAllAudio && window.amgiStopAllAudio();") { _, error in
                if let error { Log.review.error("stopAllAudio script failed: \(error)") }
            }
        }

        // Force bottom content inset so card content can always scroll above the floating
        // action bar. WKWebView does not reliably inherit SwiftUI safeAreaInset changes,
        // so we set it explicitly via DispatchQueue.main.async to override any WebKit-internal
        // layout pass that might run after updateUIView.
        let targetInset = bottomContentInset
        #if os(iOS)
        DispatchQueue.main.async {
            webView.scrollView.contentInset.bottom = targetInset
            webView.scrollView.verticalScrollIndicatorInsets.bottom = targetInset
        }
        #endif
    }

    // MARK: - Helpers

    /// Loads the frame HTML template from the bundled CardWebViewBridge.js resource.
    /// Despite the .js extension, this file is the complete HTML frame document
    /// (including <style> and <script> blocks) with runtime placeholder tokens.
    /// It is named .js because the resource was extracted under that name in Task 8.
    // Internal rather than private: the HTML builder lives in
    // CardHTMLBuilder.swift now, and `private` is file-scoped.
    static let bridgeFrameTemplate: String = {
        guard let url = Bundle.main.url(forResource: "CardWebViewBridge", withExtension: "js", subdirectory: "Review"),
              let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else {
            assertionFailure("CardWebViewBridge.js missing from bundle — regenerate xcodeproj")
            return ""
        }
        return str
    }()

    /// Tap-to-lookup user script. Listens for click events at the
    /// capture phase, skips when there's an active selection (so taps
    /// that dismiss selection don't also fire a lookup), grabs ~32
    /// chars of text from the caret point, and posts to the native
    /// `amgiLookupText` handler with the phrase + tap coordinates +
    /// surrounding sentence context. Mirrors the chapter reader's
    /// gesture so reviewer + reader behave the same.
    private static let tapLookupBootstrapJS = """
    document.addEventListener('click', function(e) {
      const sel = window.getSelection();
      if (sel && sel.toString().length > 0) { return; }
      const range = document.caretRangeFromPoint(e.clientX, e.clientY);
      if (!range) { return; }
      let phrase = '';
      let node = range.startContainer;
      let offset = range.startOffset;
      while (node && phrase.length < 32) {
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
      if (phrase.length > 0) {
        window.webkit.messageHandlers.amgiLookupText.postMessage({
          text: phrase,
          sentence: '',
          x: e.clientX,
          y: e.clientY
        });
      }
    }, true);
    """

    /// Loads a blank page in a new WKWebView so WebKit's process pool is
    /// already warm when the first real card appears. `makeCoordinator`
    /// adopts the paired coordinator (and its webview) via the prewarmer's
    /// `take()`; the frame page self-heals to the real card through the
    /// page-signature reload.
    @MainActor
    static func attachPrewarmedFrame(to coordinator: CardWebViewCoordinator) {
        let webView = WKWebView()
        coordinator.prewarmedWebView = webView
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }
}

#if os(iOS)
private struct CardWebViewPlatformHost: UIViewRepresentable {
    let card: CardWebView

    func makeCoordinator() -> CardWebViewCoordinator {
        card.makeCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.prewarmedWebView ?? card.makeConfiguredWebView(coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: CardWebViewCoordinator) {
        CardWebView.dismantleConfigured(webView, coordinator: coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        card.applyUpdate(webView, coordinator: context.coordinator)
    }
}
#else
private struct CardWebViewPlatformHost: NSViewRepresentable {
    let card: CardWebView

    func makeCoordinator() -> CardWebViewCoordinator {
        card.makeCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.prewarmedWebView ?? card.makeConfiguredWebView(coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: CardWebViewCoordinator) {
        CardWebView.dismantleConfigured(nsView, coordinator: coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        card.applyUpdate(nsView, coordinator: context.coordinator)
    }
}
#endif
