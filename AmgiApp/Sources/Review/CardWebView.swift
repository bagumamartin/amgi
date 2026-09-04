import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AVFoundation
import AmgiCardWeb

// The representable conformance is platform-specific and lives in the
// extensions at the bottom of this file; the struct body itself is shared.
struct CardWebView {
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
    let onQuestionCanvasTap: (() -> Void)?

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
        onLookupRequested: ((String?, String?, CGPoint) -> Void)? = nil,
        onQuestionCanvasTap: (() -> Void)? = nil
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
        self.onQuestionCanvasTap = onQuestionCanvasTap
    }

    @MainActor
    func makeCoordinator() -> CardWebViewCoordinator {
        // Adopt the prewarmed pair when available: the returned coordinator
        // already owns a loaded frame page and its webview, so the review's
        // first HTML card skips the WebKit process cold-start entirely.
        if let prewarmed = CardWebViewPrewarmer.shared.take() {
            return prewarmed
        }
        return CardWebViewCoordinator(
            onAudioStateChange: onAudioStateChange,
            onCardBackgroundColorChange: onCardBackgroundColorChange,
            onLookupRequested: onLookupRequested,
            onQuestionCanvasTap: onQuestionCanvasTap
        )
    }

    /// Builds the card webview. The iOS tap-interaction handlers and user
    /// script are registered unconditionally: the prewarm pool creates this
    /// configuration before any session's callbacks exist, and over-injection
    /// is safe because JS messages land in the coordinator, whose (nil)
    /// callbacks gate every behaviour — lookup posts are dropped when no
    /// `onLookupRequested` is wired, reveal taps when none is wired.
    @MainActor
    static func makeCardWebView(coordinator: CardWebViewCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(CardAssetScheme(), forURLScheme: CardAssetPath.scheme)
        config.userContentController.add(coordinator, name: "amgiAudioState")
        config.userContentController.add(coordinator, name: "amgiOpenLink")
        config.userContentController.add(coordinator, name: "amgiSpeakTts")
        config.userContentController.add(coordinator, name: "amgiStopTts")
        config.userContentController.add(coordinator, name: "amgiCardTheme")
        config.userContentController.add(coordinator, name: "amgiDiag")
        #if os(iOS)
        config.userContentController.add(coordinator, name: "amgiLookupText")
        config.userContentController.add(coordinator, name: "amgiRevealAnswer")
        config.userContentController.addUserScript(WKUserScript(
            source: tapInteractionBootstrapJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        #endif

        // Enable media playback without user interaction
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif

        let webView = CardHostWebView(frame: .zero, configuration: config)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        #else
        webView.underPageBackgroundColor = .clear
        #endif
        webView.navigationDelegate = coordinator
        return webView
    }

    /// Prewarm entry point: pairs a fresh webview with `coordinator`, loads
    /// the frame page for the current appearance, and records the page
    /// signature exactly as `applyCardUpdate` would — so adoption continues
    /// through the normal update path with no special cases.
    @MainActor
    static func attachPrewarmedFrame(to coordinator: CardWebViewCoordinator) {
        let webView = makeCardWebView(coordinator: coordinator)
        let isDarkMode = currentAppearanceIsDark()
        coordinator.lastPageSignature = "\(isDarkMode)"
        coordinator.isPageLoaded = false
        coordinator.pendingUpdateScript = nil
        webView.loadHTMLString(framePageHTML(isDarkMode: isDarkMode), baseURL: CardAssetPath.cardBaseURL)
        coordinator.prewarmedWebView = webView
    }

    @MainActor
    static func currentAppearanceIsDark() -> Bool {
        #if os(iOS)
        return UITraitCollection.current.userInterfaceStyle == .dark
        #elseif canImport(AppKit)
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        return false
        #endif
    }

    @MainActor
    fileprivate static func tearDownWebView(_ webView: WKWebView, coordinator: CardWebViewCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiAudioState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiOpenLink")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiSpeakTts")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiStopTts")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiCardTheme")
        #if os(iOS)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiLookupText")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "amgiRevealAnswer")
        #endif
        coordinator.stopTTS()
    }

    @MainActor
    fileprivate func applyCardUpdate(to webView: WKWebView, coordinator: CardWebViewCoordinator) {
        // Convert Anki [sound:filename.mp3] tags to <audio> HTML elements.
        // The Rust renderer keeps these tags literal; the client must expand them.
        let isDarkMode = colorScheme == .dark
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
        // A number of exported templates (including MarginNote exports) use
        // literal black text and a white surface without providing a dark
        // mode variant. Preserve authored colors in light mode, while making
        // only those default-looking values theme-aware in dark mode.
        let effectiveCardCSS = Self.themeCompatibleCardCSS(cardCSS, isDarkMode: isDarkMode)
        let bodyPaddingBottom = 16
        let cardPaddingBottom = 0
        let alignTop = contentAlignment == .top
        let bodyClass = Self.bodyClasses(cardOrdinal: cardOrdinal, isDarkMode: isDarkMode)
        let pageSignature = "\(isDarkMode)"
        let cssSignature = "\(effectiveCardCSS.hashValue)"
        let contentSignature = "\(autoplayEnabled)|\(isAnswerSide)|\(lookupPopupEnabled)|\(replayMode.rawValue)|\(cardOrdinal)|\(alignTop)|\(bodyPaddingBottom)|\(cardPaddingBottom)|\(cssSignature)|\(processedHTML.hashValue)|\(prefetchHTML?.hashValue ?? 0)"
        coordinator.openLinksExternally = openLinksExternally
        // Refresh every update: an adopted prewarm coordinator arrives with
        // nil callbacks and takes over this session's wiring here.
        coordinator.refreshCallbacks(
            onAudioStateChange: onAudioStateChange,
            onCardBackgroundColorChange: onCardBackgroundColorChange,
            onLookupRequested: onLookupRequested,
            onQuestionCanvasTap: onQuestionCanvasTap
        )
        coordinator.currentWebView = webView
        #if os(iOS)
        webView.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
        #endif

        // Build the JS call that shows the card – passed via evaluateJavaScript so
        // HTML content never lives inside a <script> literal in the page source.
        let showCardScript = Self.showCardScript(
            processedHTML: processedHTML,
            prefetchHTML: prefetchHTML,
            cardCSS: effectiveCardCSS,
            isAnswerSide: isAnswerSide,
            lookupPopupEnabled: lookupPopupEnabled,
            bodyClass: bodyClass,
            autoplayEnabled: autoplayEnabled,
            replayMode: replayMode.rawValue,
            alignTop: alignTop,
            bodyPaddingBottom: bodyPaddingBottom,
            cardPaddingBottom: cardPaddingBottom
        )
        coordinator.stopTTS()

        if coordinator.lastPageSignature != pageSignature {
            coordinator.lastPageSignature = pageSignature
            coordinator.lastContentSignature = contentSignature
            coordinator.isPageLoaded = false
            coordinator.pendingUpdateScript = nil
            // Stash the show-card call so we can run it once the page finishes loading.
            coordinator.pendingUpdateScript = showCardScript

            webView.loadHTMLString(
                Self.framePageHTML(isDarkMode: isDarkMode),
                baseURL: CardAssetPath.cardBaseURL
            )
        } else if coordinator.lastContentSignature != contentSignature {
            coordinator.lastContentSignature = contentSignature
            if coordinator.isPageLoaded {
                webView.evaluateJavaScript(showCardScript, completionHandler: nil)
            } else {
                coordinator.pendingUpdateScript = showCardScript
            }
        }
        if replayRequestID != coordinator.lastReplayRequestID {
            coordinator.lastReplayRequestID = replayRequestID
            webView.evaluateJavaScript("window.amgiReplayAll && window.amgiReplayAll('" + replayMode.rawValue + "');", completionHandler: nil)
        }

        if stopAudioRequestID != coordinator.lastStopAudioRequestID {
            coordinator.lastStopAudioRequestID = stopAudioRequestID
            webView.evaluateJavaScript("window.amgiStopAllAudio && window.amgiStopAllAudio();", completionHandler: nil)
        }

        // Force bottom content inset so card content can always scroll above the floating
        // action bar. WKWebView does not reliably inherit SwiftUI safeAreaInset changes,
        // so we set it explicitly via DispatchQueue.main.async to override any WebKit-internal
        // layout pass that might run after updateUIView. macOS WKWebView has no
        // UIScrollView; the floating action bar is laid out by SwiftUI there.
        #if os(iOS)
        let targetInset = bottomContentInset
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
    private static let bridgeFrameTemplate: String = {
        guard let url = Bundle.main.url(forResource: "CardWebViewBridge", withExtension: "js", subdirectory: "Review"),
              let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else {
            assertionFailure("CardWebViewBridge.js missing from bundle — regenerate xcodeproj")
            return ""
        }
        return str
    }()

    #if os(iOS)
    /// Tap-to-lookup + tap-to-reveal bootstrap. Always injected with both
    /// behaviours enabled: the coordinator-side callbacks are nil whenever a
    /// feature is off, and every posted message dies on optional chaining —
    /// so injection no longer needs to know the session's preferences (the
    /// prewarm pool builds this configuration before any session exists).
    private static let tapInteractionBootstrapJS: String = {
        return """
        (function() {
          const lookupEnabled = true;
          const revealEnabled = true;
          const longPressDelay = 500;
          const movementThreshold = 12;
          var touchState = null;
          var lastTouchActionAt = 0;

          function interactiveTarget(target) {
            return target && target.closest(
              'a, button, input, textarea, select, option, video, audio, iframe,' +
              ' [role="button"], [contenteditable="true"], [data-amgi-interactive],' +
              ' [onclick], .replay-button, .replay-btn, .sound-btn, .soundLink,' +
              ' #image-occlusion-canvas'
            );
          }

          function selectedTextExists() {
            const selection = window.getSelection();
            return !!(selection && selection.toString().length > 0);
          }

          function interactionDisabled() {
            return !!amgiCardState().isAnswerSide || !!document.getElementById('typeans');
          }

          function touchPoint(event) {
            const touch = event.changedTouches && event.changedTouches[0];
            return touch ? { x: touch.clientX, y: touch.clientY } : null;
          }

          function textPayloadAt(point) {
            if (!lookupEnabled || !point || typeof amgiCardLookupPayloadAt !== 'function') return null;
            return amgiCardLookupPayloadAt(point.x, point.y, 16);
          }

          function sendLookup(point) {
            const payload = textPayloadAt(point);
            if (!payload || !window.webkit.messageHandlers.amgiLookupText) return false;
            window.webkit.messageHandlers.amgiLookupText.postMessage(payload);
            return true;
          }

          function cancelTouch() {
            if (!touchState) return;
            window.clearTimeout(touchState.timer);
            touchState = null;
          }

          document.addEventListener('touchstart', function(event) {
            if (event.touches.length !== 1 || selectedTextExists() || interactionDisabled()) return;
            const target = event.target instanceof Element ? event.target : null;
            if (!target || interactiveTarget(target)) return;
            const point = touchPoint(event);
            if (!point) return;

            touchState = {
              target: target,
              start: point,
              moved: false,
              longPressed: false,
              timer: window.setTimeout(function() {
                if (!touchState || touchState.moved || !lookupEnabled) return;
                if (sendLookup(touchState.start)) {
                  touchState.longPressed = true;
                }
              }, longPressDelay)
            };
          }, { passive: true });

          document.addEventListener('touchmove', function(event) {
            if (!touchState) return;
            const point = touchPoint(event);
            if (!point) return;
            const dx = point.x - touchState.start.x;
            const dy = point.y - touchState.start.y;
            if (Math.sqrt(dx * dx + dy * dy) > movementThreshold) {
              touchState.moved = true;
              cancelTouch();
            }
          }, { passive: true });

          document.addEventListener('touchend', function(event) {
            if (!touchState) return;
            const state = touchState;
            const point = touchPoint(event) || state.start;
            window.clearTimeout(state.timer);
            touchState = null;
            if (state.moved || state.longPressed || selectedTextExists() || interactionDisabled()) return;
            if (!revealEnabled || interactiveTarget(state.target)) return;
            lastTouchActionAt = Date.now();
            window.webkit.messageHandlers.amgiRevealAnswer.postMessage(null);
          }, { passive: true });

          document.addEventListener('touchcancel', cancelTouch, { passive: true });

          // WebKit normally delivers touchstart/touchend, but a host scroll
          // gesture can occasionally drop that sequence while still emitting
          // the synthesized click. Keep a guarded fallback so a simple tap
          // remains a reveal without duplicating the touch path.
          document.addEventListener('click', function(event) {
            if (Date.now() - lastTouchActionAt < 700) return;
            if (!revealEnabled || interactionDisabled() || selectedTextExists()) return;
            const target = event.target instanceof Element ? event.target : null;
            if (!target || interactiveTarget(target)) return;
            lastTouchActionAt = Date.now();
            window.webkit.messageHandlers.amgiRevealAnswer.postMessage(null);
          }, false);
        })();
        """
    }()
    #endif
}

private extension CardWebView {
    /// Assembles the static frame document from the bridge template with all
    /// placeholder tokens resolved. Shared by the update-path reload and the
    /// prewarm loader so both produce byte-identical pages.
    @MainActor
    static func framePageHTML(isDarkMode: Bool) -> String {
        let htmlClass = htmlClasses(isDarkMode: isDarkMode)
        let playIconHTML = audioButtonIconHTML(systemName: "play.circle", alt: "Play", isDarkMode: isDarkMode)
        let pauseIconHTML = audioButtonIconHTML(systemName: "pause.circle", alt: "Pause", isDarkMode: isDarkMode)
        let baseTag = CardAssetPath.mediaBaseTag()
        return buildFrameHTML(
            htmlClass: htmlClass,
            isDarkMode: isDarkMode,
            playIconHTML: playIconHTML,
            pauseIconHTML: pauseIconHTML,
            baseTag: baseTag
        )
    }

    /// Builds the static HTML frame page (no card content). Card HTML is injected
    /// later via evaluateJavaScript (_showQuestion/_showAnswer) so that arbitrary
    /// HTML never lives inside a <script> literal in the page source.
    static func buildFrameHTML(
        htmlClass: String,
        isDarkMode: Bool,
        playIconHTML: String,
        pauseIconHTML: String,
        baseTag: String
    ) -> String {
        let colorScheme = isDarkMode ? "dark" : "light"
        // Keep the frame background transparent in both light and dark modes.
        // The review toolbar/bottom chrome must sample the rendered card template
        // background; reintroducing a dark-only fallback here makes the wrapper
        // background win over the template color and breaks auto-match again.
        let defaultCardBackground = "transparent"
        let textColor = isDarkMode ? "#f5f5f5" : "#1a1a1a"
        let hrColor = isDarkMode ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.2)"
        let typeBorderColor = isDarkMode ? "rgba(255,255,255,0.28)" : "rgba(0,0,0,0.22)"
        let typeBgColor = isDarkMode ? "rgba(255,255,255,0.08)" : "rgba(255,255,255,0.9)"
        let typeFocusBorder = isDarkMode ? "rgba(143,184,255,0.9)" : "rgba(0,122,255,0.9)"
        let typeFocusShadow = isDarkMode ? "rgba(143,184,255,0.18)" : "rgba(0,122,255,0.15)"
        let typeCodeBg = isDarkMode ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)"
        let missingMediaColor = isDarkMode ? "rgba(255,100,100,0.9)" : "rgba(200,40,40,0.8)"
        let playIconLiteral = jsStringLiteral(playIconHTML)
        let pauseIconLiteral = jsStringLiteral(pauseIconHTML)
        let mathJaxConfigScriptURL = jsStringLiteral(CardAssetPath.mathJaxConfigScriptURLString)
        let mathJaxCoreScriptURL = jsStringLiteral(CardAssetPath.mathJaxCoreScriptURLString)

        return bridgeFrameTemplate
            .replacingOccurrences(of: "__AMGI_HTML_CLASS__", with: htmlClass)
            .replacingOccurrences(of: "__AMGI_COLOR_SCHEME__", with: colorScheme)
            .replacingOccurrences(of: "__AMGI_DEFAULT_CARD_BG__", with: defaultCardBackground)
            .replacingOccurrences(of: "__AMGI_TEXT_COLOR__", with: textColor)
            .replacingOccurrences(of: "__AMGI_HR_COLOR__", with: hrColor)
            .replacingOccurrences(of: "__AMGI_TYPE_BORDER_COLOR__", with: typeBorderColor)
            .replacingOccurrences(of: "__AMGI_TYPE_BG_COLOR__", with: typeBgColor)
            .replacingOccurrences(of: "__AMGI_TYPE_FOCUS_BORDER__", with: typeFocusBorder)
            .replacingOccurrences(of: "__AMGI_TYPE_FOCUS_SHADOW__", with: typeFocusShadow)
            .replacingOccurrences(of: "__AMGI_TYPE_CODE_BG__", with: typeCodeBg)
            .replacingOccurrences(of: "__AMGI_MISSING_MEDIA_COLOR__", with: missingMediaColor)
            .replacingOccurrences(of: "__AMGI_PLAY_ICON_LITERAL__", with: playIconLiteral)
            .replacingOccurrences(of: "__AMGI_PAUSE_ICON_LITERAL__", with: pauseIconLiteral)
            .replacingOccurrences(of: "__AMGI_MATHJAX_CONFIG_URL__", with: mathJaxConfigScriptURL)
            .replacingOccurrences(of: "__AMGI_MATHJAX_CORE_URL__", with: mathJaxCoreScriptURL)
            .replacingOccurrences(of: "__AMGI_BASE_TAG__", with: baseTag)
    }

    /// Builds the evaluateJavaScript call that shows the card.
    /// HTML content is passed as JS string arguments – never embedded inside
    /// a <script> tag in the page source – eliminating </script> injection risk.
    static func showCardScript(
        processedHTML: String,
        prefetchHTML: String?,
        cardCSS: String,
        isAnswerSide: Bool,
        lookupPopupEnabled: Bool,
        bodyClass: String,
        autoplayEnabled: Bool,
        replayMode: String,
        alignTop: Bool,
        bodyPaddingBottom: Int,
        cardPaddingBottom: Int
    ) -> String {
        let htmlLit = jsStringLiteral(processedHTML)
        let cssLit = jsStringLiteral(cardCSS)
        let autoplay = autoplayEnabled ? "true" : "false"
        let lookupEnabled = lookupPopupEnabled ? "true" : "false"
        let alignTopStr = alignTop ? "true" : "false"
        let applyCSS = "amgiSetCardCSS(\(cssLit));"

        if isAnswerSide {
            return applyCSS + "_showAnswer(\(htmlLit),\(jsStringLiteral(bodyClass)),\(autoplay),\(jsStringLiteral(replayMode)),\(alignTopStr),\(bodyPaddingBottom),\(cardPaddingBottom),\(lookupEnabled)" + ");"
        } else {
            let prefetchLit = jsStringLiteral(prefetchHTML ?? "")
            return applyCSS + "_showQuestion(\(htmlLit),\(prefetchLit),\(jsStringLiteral(bodyClass)),\(autoplay),\(jsStringLiteral(replayMode)),\(alignTopStr),\(bodyPaddingBottom),\(cardPaddingBottom),\(lookupEnabled)" + ");"
        }
    }

    /// Makes common light-only exported templates readable in dark mode
    /// without applying a destructive global invert/filter to their content.
    /// Deliberate colors, images, diagrams, and background images are left
    /// alone; only exact black/white defaults in color declarations are
    /// replaced with the bridge's theme variables.
    static func themeCompatibleCardCSS(_ css: String, isDarkMode: Bool) -> String {
        guard isDarkMode, !css.isEmpty else { return css }

        var result = css
        let blackPattern = #"(?i)(\bcolor\s*:\s*)(#(?:000|000000)|black|rgb\s*\(\s*0\s*,\s*0\s*,\s*0\s*\))\b"#
        let whitePattern = #"(?i)(\bbackground(?:-color)?\s*:\s*)(#(?:fff|ffffff)|white|rgb\s*\(\s*255\s*,\s*255\s*,\s*255\s*\))\b"#

        if let regex = try? NSRegularExpression(pattern: blackPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1var(--amgi-card-fg)"
            )
        }
        if let regex = try? NSRegularExpression(pattern: whitePattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1var(--amgi-card-bg)"
            )
        }
        return result
    }

    /// Converts Anki `[sound:filename.ext]` markers to a hidden `<audio>` + styled play button.
    static func expandSoundTags(
        _ html: String,
        isDarkMode: Bool,
        showReplayButtons: Bool
    ) -> String {
        // Pattern: [sound:anything_without_closing_bracket]
        guard let regex = try? NSRegularExpression(
            pattern: #"\[sound:([^\]]+)\]"#, options: []
        ) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        var result = html
        // Process in reverse order to preserve character indices
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let filenameRange = Range(match.range(at: 1), in: result) else { continue }
            let filename = String(result[filenameRange])
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            let replacement: String
            if showReplayButtons {
                let iconHTML = audioButtonIconHTML(systemName: "play.circle", alt: "Play", isDarkMode: isDarkMode)
                replacement = "<span class=\"sound-btn\"><audio class=\"anki-sound-audio\" src=\"\(encoded)\" preload=\"auto\"></audio><a class=\"replay-button replay-btn soundLink\" href=\"#\" draggable=\"false\" onclick=\"return playSound(this)\">\(iconHTML)</a></span>"
            } else {
                replacement = "<span class=\"sound-btn\"><audio class=\"anki-sound-audio\" src=\"\(encoded)\" preload=\"auto\"></audio></span>"
            }
            result.replaceSubrange(matchRange, with: replacement)
        }
        return result
    }

    static func expandTTSTags(
        in html: String,
        isDarkMode: Bool,
        showReplayButtons: Bool
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[anki:tts([^\]]*)\](.*?)\[/anki:tts\]"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return html }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        var result = html

        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let attrsRange = Range(match.range(at: 1), in: result),
                  let textRange = Range(match.range(at: 2), in: result) else { continue }

            let options = parseTTSAttributes(String(result[attrsRange]))
            let spokenText = String(result[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lang = options["lang"] ?? ""
            let voices = options["voices"] ?? ""
            let speed = options["speed"] ?? ""

            let replacement: String
            if showReplayButtons {
                let iconHTML = audioButtonIconHTML(systemName: "play.circle", alt: "Speak", isDarkMode: isDarkMode)
                replacement = "<a class=\"replay-button replay-btn tts-btn\" href=\"#\" draggable=\"false\" data-tts-text=\"\(htmlAttributeEscaped(spokenText))\" data-tts-lang=\"\(htmlAttributeEscaped(lang))\" data-tts-voices=\"\(htmlAttributeEscaped(voices))\" data-tts-speed=\"\(htmlAttributeEscaped(speed))\" onclick=\"return amgiSpeakTts(this)\">\(iconHTML)</a>"
            } else {
                replacement = ""
            }

            result.replaceSubrange(matchRange, with: replacement)
        }

        return result
    }

    static func deferCardScripts(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b([^>]*)>"#,
            options: [.caseInsensitive]
        ) else { return html }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        var result = html

        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let attrsRange = Range(match.range(at: 1), in: result) else { continue }

            let attrs = String(result[attrsRange])
            let withoutQuotedType = attrs.replacingOccurrences(
                of: #"\stype\s*=\s*(["']).*?\1"#,
                with: "",
                options: .regularExpression
            )
            let cleanedAttrs = withoutQuotedType.replacingOccurrences(
                of: #"\stype\s*=\s*[^\s>]+"#,
                with: "",
                options: .regularExpression
            )

            let replacement = "<script type=\"application/x-amgi-card-script\" data-amgi-card-script=\"1\"\(cleanedAttrs)>"
            result.replaceSubrange(matchRange, with: replacement)
        }

        return result
    }

    static func parseTTSAttributes(_ raw: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_]+)=([^\s\]]+)"#,
            options: []
        ) else { return [:] }

        let range = NSRange(raw.startIndex..., in: raw)
        let matches = regex.matches(in: raw, range: range)
        var result: [String: String] = [:]
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: raw),
                  let valueRange = Range(match.range(at: 2), in: raw) else { continue }
            result[String(raw[keyRange]).lowercased()] = String(raw[valueRange])
        }
        return result
    }

    static func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Renders an SF Symbol to a tinted PNG data URI for the in-card audio
    /// replay buttons. Same output on both platforms; only the rendering
    /// path differs (UIGraphicsImageRenderer vs NSImage lockFocus).
    static func audioButtonIconHTML(systemName: String, alt: String, isDarkMode: Bool) -> String {
        #if canImport(UIKit)
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular, scale: .medium)
        let tint = isDarkMode ? UIColor.white : UIColor(red: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
        guard let baseImage = UIImage(systemName: systemName, withConfiguration: configuration) else {
            return alt
        }

        let image = baseImage.withTintColor(tint, renderingMode: .alwaysOriginal)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let rendered = renderer.image { _ in
            image.draw(at: .zero)
        }

        guard let data = rendered.pngData() else {
            return alt
        }
        #elseif canImport(AppKit)
        let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let tint = isDarkMode ? NSColor.white : NSColor(red: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
        guard let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: alt)?
            .withSymbolConfiguration(configuration) else {
            return alt
        }

        // Drawing a template image picks up the current fill colour as its
        // tint, so set the tint then draw.
        baseImage.isTemplate = true
        let rendered = NSImage(size: baseImage.size)
        rendered.lockFocus()
        tint.setFill()
        baseImage.draw(
            in: CGRect(origin: .zero, size: baseImage.size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        rendered.unlockFocus()

        guard let cgImage = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            return alt
        }
        #else
        return alt
        #endif

        return "<img class=\"amgi-inline-icon\" src=\"data:image/png;base64,\(data.base64EncodedString())\" alt=\"\(alt)\" draggable=\"false\" style=\"width:28px;height:28px;max-width:none;display:block;flex:none;\" />"
    }

    static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            // Escape </script> so it doesn't prematurely close the enclosing <script> block
            .replacingOccurrences(of: "</script>", with: "<\\/script>", options: .caseInsensitive)
        return "'\(escaped)'"
    }

    static func bodyClasses(cardOrdinal: UInt32, isDarkMode: Bool) -> String {
        var classes = ["card", "card\(Int(cardOrdinal) + 1)"]
        if isDarkMode {
            classes.append("nightMode")
            classes.append("night_mode")
        }
        return classes.joined(separator: " ")
    }

    @MainActor
    static func htmlClasses(isDarkMode: Bool) -> String {
        var classes: [String] = []

        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            classes.append("ios")
            classes.append("ipad")
            classes.append("mobile")
        case .phone:
            classes.append("ios")
            classes.append("iphone")
            classes.append("mobile")
        default:
            break
        }
        #else
        // Anki templates key styling off platform classes; match the set
        // Anki Desktop attaches on macOS.
        classes.append("mac")
        classes.append("desktop")
        #endif

        if isDarkMode {
            classes.append("nightMode")
            classes.append("night_mode")
        }

        return classes.joined(separator: " ")
    }
}

/// Card renderer that does not steal hardware-keyboard events from SwiftUI.
///
/// WKWebView becomes first responder on click/tap and then eats ⌘Z (its
/// empty undo manager is a no-op) and iPad arrow keys (focus navigation).
/// Cards aren't editable; lookup is JS-on-tap, so declining first-responder
/// status keeps review shortcuts on the SwiftUI surface.
#if os(iOS)
private final class CardHostWebView: WKWebView {
    override var canBecomeFirstResponder: Bool { false }
}
#elseif os(macOS)
private final class CardHostWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
#endif

// MARK: - Platform representable conformance

#if os(iOS)
extension CardWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        // When this coordinator came from the prewarm pool, its webview is
        // already configured and frame-loaded — hand it over instead of
        // building a second one that would cold-start WebKit's processes.
        context.coordinator.prewarmedWebView ?? Self.makeCardWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        applyCardUpdate(to: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: CardWebViewCoordinator) {
        tearDownWebView(webView, coordinator: coordinator)
    }
}
#else
extension CardWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.prewarmedWebView ?? Self.makeCardWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        applyCardUpdate(to: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CardWebViewCoordinator) {
        tearDownWebView(webView, coordinator: coordinator)
    }
}
#endif
