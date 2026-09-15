import Testing
@testable import ReviewFeature

@Suite struct ThemeCompatibleCardCSSTests {
    @Test func lightModeLeavesAuthoredColorsAlone() {
        let css = "color: black; background-color: white;"
        #expect(CardWebView.themeCompatibleCardCSS(css, isDarkMode: false) == css)
    }

    @Test func darkModeRewritesExactBlackAndWhiteOntoFrameTokens() {
        let css = "color: #000; background: #fff; color: black; background-color: white;"
        let rewritten = CardWebView.themeCompatibleCardCSS(css, isDarkMode: true)
        #expect(rewritten.contains("var(--amgi-card-fg)"))
        #expect(rewritten.contains("var(--amgi-card-bg)"))
        #expect(!rewritten.contains("#000"))
        #expect(!rewritten.contains("#fff"))
    }

    @Test func darkModeLeavesNonBlackWhiteColors() {
        let css = "color: #333; background-color: #fafafa;"
        #expect(CardWebView.themeCompatibleCardCSS(css, isDarkMode: true) == css)
    }
}
