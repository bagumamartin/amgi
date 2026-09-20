import Foundation
import AmgiCardWeb

/// Inspector preview HTML: Anki's card classes, review-like defaults, and
/// "Answer Only" (the portion after `<hr id=answer>`, not the whole back).
enum BrowsePreviewHTML {
    /// Front, back, or just the answer field depending on the preview mode.
    static func displayHTML(
        front: String,
        back: String,
        showAnswer: Bool,
        answerOnly: Bool
    ) -> String {
        if answerOnly { return answerHTML(from: back) }
        return showAnswer ? back : front
    }

    /// Anki backs typically prepend the question and a `<hr id=answer>` rule.
    /// Answer Only should show the answer field, not that whole back template.
    static func answerHTML(from backHTML: String) -> String {
        let pattern = #"<hr\b[^>]*\bid\s*=\s*(?:["']answer["']|answer\b)[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: backHTML,
                range: NSRange(backHTML.startIndex..., in: backHTML)
              ),
              let range = Range(match.range, in: backHTML)
        else {
            return backHTML
        }
        let answer = String(backHTML[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? backHTML : answer
    }

    static func wrappedDocument(
        html: String,
        css: String,
        isDarkMode: Bool,
        cardOrdinal: Int32
    ) -> String {
        let body = CardHTMLRewriter.rewrite(html)
        let textColor = isDarkMode ? "#f5f5f5" : "#1a1a1a"
        let hrColor = isDarkMode ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.18)"
        let compatibleCSS = themeCompatibleCardCSS(css, isDarkMode: isDarkMode)
        let ordinal = max(0, Int(cardOrdinal)) + 1
        var classes = ["card", "card\(ordinal)"]
        if isDarkMode {
            classes.append("nightMode")
            classes.append("night_mode")
        }
        let bodyClass = classes.joined(separator: " ")
        let htmlClass = isDarkMode ? "nightMode" : ""
        return """
        <html class="\(htmlClass)"><head>\(CardAssetPath.mediaBaseTag())\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>
        :root {
            color-scheme: \(isDarkMode ? "dark" : "light");
            --amgi-card-fg: \(textColor);
            --amgi-card-bg: transparent;
        }
        html, body {
            background: transparent;
            overflow-x: hidden;
        }
        body {
            font-family: -apple-system, system-ui, "Segoe UI", sans-serif;
            font-size: 20px;
            line-height: 1.55;
            color: var(--amgi-card-fg);
            background: var(--amgi-card-bg);
            margin: 16px 28px 96px;
            text-align: center;
            overflow-wrap: break-word;
        }
        hr { border: none; border-top: 1px solid \(hrColor); margin: 20px auto; max-width: 32em; }
        img, video { max-width: 100%; height: auto; border-radius: 12px; }
        li, pre, table { text-align: start; }
        .amgi-play {
            appearance: none; border: 0;
            background: color-mix(in srgb, currentColor 12%, transparent);
            color: inherit; border-radius: 999px;
            width: 36px; height: 36px; font-size: 13px;
            margin: 4px;
        }
        audio { display: none; }
        .cloze { font-weight: 600; color: \(isDarkMode ? "#8fb8ff" : "#1565c0"); }
        \(compatibleCSS)
        html, body, body.card, .card {
            background: transparent !important;
            background-color: transparent !important;
        }
        </style>
        <script>
        function amgiPlay(id) {
            var el = document.getElementById(id);
            if (!el) return;
            el.currentTime = 0;
            el.play();
        }
        </script>\
        </head><body class="\(bodyClass)">\(body)</body></html>
        """
    }

    /// Dark mode only: rewrite exact black text / white backgrounds in
    /// template CSS onto the frame tokens so light-authored cards remain
    /// readable. Mirrors `CardWebView.themeCompatibleCardCSS`.
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
}
