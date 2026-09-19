#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bidirectional codec between Anki field HTML fragments and an attributed
/// string the note editor can show. Does **not** use `NSAttributedString`'s
/// HTML importer (crash-prone); this is a small allowlisted fragment parser.
enum NoteFieldHTML {
    #if canImport(UIKit)
    typealias Font = UIFont
    typealias PlatformImage = UIImage
    #else
    typealias Font = NSFont
    typealias PlatformImage = NSImage
    #endif

    static let zeroWidthSpace = "\u{200B}"
    static let indentStep: CGFloat = 24
    static let maxIndent = 6

    static let listKindKey = NSAttributedString.Key("amgi.noteField.listKind")
    static let alignmentKey = NSAttributedString.Key("amgi.noteField.alignment")
    static let indentKey = NSAttributedString.Key("amgi.noteField.indent")
    static let imageFilenameKey = NSAttributedString.Key("amgi.noteField.imageFilename")

    enum Alignment: Int, Equatable, Sendable {
        case unspecified = 0
        case left = 1
        case center = 2
        case right = 3

        var css: String {
            switch self {
            case .unspecified, .left: "left"
            case .center: "center"
            case .right: "right"
            }
        }

        #if canImport(UIKit)
        var nsTextAlignment: NSTextAlignment {
            switch self {
            case .unspecified: .natural
            case .left: .left
            case .center: .center
            case .right: .right
            }
        }
        #else
        var nsTextAlignment: NSTextAlignment {
            switch self {
            case .unspecified: .natural
            case .left: .left
            case .center: .center
            case .right: .right
            }
        }
        #endif
    }

    enum ListKind: Int, Equatable, Sendable {
        case none = 0
        case bullet = 1
        case numbered = 2
        case circle = 3
        case square = 4
        case lowerAlpha = 5
        case upperAlpha = 6
        case lowerRoman = 7
        case upperRoman = 8

        var isBullet: Bool {
            self == .bullet || self == .circle || self == .square
        }

        var isNumbered: Bool {
            switch self {
            case .numbered, .lowerAlpha, .upperAlpha, .lowerRoman, .upperRoman: true
            default: false
            }
        }

        var htmlTag: String { isNumbered ? "ol" : "ul" }

        var cssType: String {
            switch self {
            case .none: "none"
            case .bullet: "disc"
            case .circle: "circle"
            case .square: "square"
            case .numbered: "decimal"
            case .lowerAlpha: "lower-alpha"
            case .upperAlpha: "upper-alpha"
            case .lowerRoman: "lower-roman"
            case .upperRoman: "upper-roman"
            }
        }

        var markerFormat: NSTextList.MarkerFormat {
            switch self {
            case .none, .bullet: .disc
            case .circle: .circle
            case .square: .square
            case .numbered: .decimal
            case .lowerAlpha: .lowercaseAlpha
            case .upperAlpha: .uppercaseAlpha
            case .lowerRoman: .lowercaseRoman
            case .upperRoman: .uppercaseRoman
            }
        }

        static func fromCSS(_ value: String) -> ListKind? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "A": return .upperAlpha
            case "I": return .upperRoman
            case "a": return .lowerAlpha
            case "i": return .lowerRoman
            case "1": return .numbered
            default: break
            }
            switch trimmed.lowercased() {
            case "disc", "disc-outside", "disc-inside": return .bullet
            case "circle": return .circle
            case "square", "box": return .square
            case "decimal", "decimal-leading-zero": return .numbered
            case "lower-alpha", "lower-latin": return .lowerAlpha
            case "upper-alpha", "upper-latin": return .upperAlpha
            case "lower-roman": return .lowerRoman
            case "upper-roman": return .upperRoman
            default: return nil
            }
        }
    }

    struct Style: Equatable, Sendable {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var superscript = false
        var `subscript` = false
        var code = false
        /// Hex CSS color (`#rrggbb`), round-tripped through `<span style>`
        /// / `<font color>`. Nil = default label color (no span emitted).
        var textColorHex: String?
        /// Hex CSS highlight, round-tripped as `background-color`. Nil = none.
        var highlightHex: String?
        /// Hyperlink target, round-tripped through `<a href>`. Nil = no link.
        var linkHref: String?
    }

    static let linkHrefKey = NSAttributedString.Key("amgi.noteField.linkHref")
    static let textColorHexKey = NSAttributedString.Key("amgi.noteField.textColorHex")
    static let highlightHexKey = NSAttributedString.Key("amgi.noteField.highlightHex")

    struct BlockStyle: Equatable, Sendable {
        var listKind: ListKind = .none
        var alignment: Alignment = .unspecified
        var indent: Int = 0
    }

    static func defaultFont() -> Font {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body)
        #else
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #endif
    }

    static func attributedString(
        from html: String,
        font: Font = defaultFont()
    ) -> NSAttributedString {
        parse(normalizeMathJax(html), font: font)
    }

    static func encode(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }

        var output = ""
        var listStack: [(kind: ListKind, indent: Int)] = []
        let ns = attributed.string as NSString
        var location = 0

        func closeLists(downTo indent: Int) {
            while let last = listStack.last, last.indent >= indent {
                output += "</\(last.kind.htmlTag)>"
                listStack.removeLast()
            }
        }

        func openList(_ kind: ListKind, indent: Int) {
            output += "<\(kind.htmlTag) style=\"list-style-type: \(kind.cssType); text-align: left\">"
            listStack.append((kind, indent))
        }

        while location < attributed.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            if paragraph.length > 0, ns.character(at: paragraph.location + paragraph.length - 1) == 10 {
                content.length -= 1
            }
            let block = blockStyle(in: attributed, at: min(paragraph.location, max(0, attributed.length - 1)))
            if block.listKind == .none {
                closeLists(downTo: 0)
                let encoded = encodeRuns(attributed, range: content)
                if block.alignment != .unspecified || block.indent > 0 {
                    var css: [String] = []
                    if block.alignment != .unspecified {
                        css.append("text-align: \(block.alignment.css)")
                    }
                    if block.indent > 0 {
                        css.append("margin-left: \(Int(CGFloat(block.indent) * indentStep))px")
                    }
                    output += "<div style=\"\(css.joined(separator: "; "))\">\(encoded)</div>"
                } else {
                    output += encoded
                    if paragraph.location + paragraph.length < attributed.length {
                        output += "<br>"
                    }
                }
            } else {
                let indent = max(0, block.indent)
                while let last = listStack.last, last.indent > indent || (last.indent == indent && last.kind != block.listKind) {
                    output += "</\(last.kind.htmlTag)>"
                    listStack.removeLast()
                }
                while listStack.last.map({ $0.indent < indent }) ?? true {
                    let nextIndent = (listStack.last?.indent ?? -1) + 1
                    openList(block.listKind, indent: nextIndent)
                }
                if listStack.isEmpty {
                    openList(block.listKind, indent: indent)
                }
                output += "<li>\(encodeRuns(attributed, range: content))</li>"
            }
            location = paragraph.location + paragraph.length
        }
        closeLists(downTo: 0)
        return output
    }

    static func listKind(in attributed: NSAttributedString, at location: Int) -> ListKind {
        blockStyle(in: attributed, at: location).listKind
    }

    static func blockStyle(in attributed: NSAttributedString, at location: Int) -> BlockStyle {
        guard attributed.length > 0 else { return .init() }
        let loc = min(max(0, location), attributed.length - 1)
        return blockStyle(from: attributed.attributes(at: loc, effectiveRange: nil))
    }

    static func blockStyle(from attributes: [NSAttributedString.Key: Any]) -> BlockStyle {
        var block = BlockStyle()
        if let raw = attributes[listKindKey] as? Int {
            block.listKind = ListKind(rawValue: raw) ?? .none
        }
        if let raw = attributes[alignmentKey] as? Int {
            block.alignment = Alignment(rawValue: raw) ?? .unspecified
        }
        if let raw = attributes[indentKey] as? Int {
            block.indent = min(maxIndent, max(0, raw))
        }
        return block
    }

    static func nextClozeOrdinal(in fields: [String]) -> Int {
        let pattern = try? NSRegularExpression(pattern: #"\{\{c(\d+)::"#)
        var maxOrdinal = 0
        for field in fields {
            let ns = field as NSString
            pattern?.enumerateMatches(in: field, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                maxOrdinal = max(maxOrdinal, Int(ns.substring(with: match.range(at: 1))) ?? 0)
            }
        }
        return maxOrdinal + 1
    }

    static func wrapCloze(_ text: String, selected: NSRange, ordinal: Int) -> (text: String, selected: NSRange) {
        let source = text as NSString
        let prefix = "{{c\(ordinal)::"
        let suffix = "}}"
        let selectedText = source.substring(with: selected)
        let replacement = "\(prefix)\(selectedText)\(suffix)"
        let updated = source.replacingCharacters(in: selected, with: replacement)
        let inner = NSRange(location: selected.location + (prefix as NSString).length, length: selected.length)
        return (updated, inner)
    }

    static func roundTrip(_ source: String, font: Font = defaultFont()) -> String {
        encode(attributedString(from: source, font: font))
    }

    static func normalizeMathJax(_ text: String) -> String {
        guard text.localizedCaseInsensitiveContains("anki-mathjax") else { return text }
        let pattern = #"<anki-mathjax(?:[^>]*?block=\"(.*?)\")?[^>]*?>(.*?)</anki-mathjax>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }

        let source = text as NSString
        var output = ""
        var currentLocation = 0

        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let fullRange = match.range(at: 0)
            output += source.substring(with: NSRange(location: currentLocation, length: fullRange.location - currentLocation))

            let blockValue: String? = {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { return nil }
                return source.substring(with: range)
            }()

            let innerText: String = {
                let range = match.range(at: 2)
                guard range.location != NSNotFound else { return "" }
                return source.substring(with: range)
            }()

            let trimmed = trimMathJaxBreaks(in: innerText)
            if let blockValue, !blockValue.isEmpty, blockValue.caseInsensitiveCompare("false") != .orderedSame {
                output += #"\["# + trimmed + #"\]"#
            } else {
                output += #"\("# + trimmed + #"\)"#
            }

            currentLocation = fullRange.location + fullRange.length
        }

        output += source.substring(from: currentLocation)
        return output
    }

    static func attributes(
        for style: Style,
        font: Font,
        block: BlockStyle = .init()
    ) -> [NSAttributedString.Key: Any] {
        attributes(for: style, font: font, listKind: block.listKind, alignment: block.alignment, indent: block.indent)
    }

    static func attributes(
        for style: Style,
        font: Font,
        listKind: ListKind = .none,
        alignment: Alignment = .unspecified,
        indent: Int = 0
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fontByApplying(style, to: font),
            .foregroundColor: platformColor(hex: style.textColorHex) ?? labelColor,
        ]
        if let highlightHex = style.highlightHex,
           let bg = platformColor(hex: highlightHex) {
            attrs[.backgroundColor] = bg
            attrs[highlightHexKey] = highlightHex
        }
        if let textColorHex = style.textColorHex {
            attrs[textColorHexKey] = textColorHex
        }
        if let href = style.linkHref, !href.isEmpty {
            attrs[linkHrefKey] = href
            #if canImport(UIKit)
            attrs[.link] = href
            #else
            attrs[.link] = href
            #endif
        }
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.superscript {
            attrs[.baselineOffset] = font.pointSize * 0.35
        } else if style.subscript {
            attrs[.baselineOffset] = -(font.pointSize * 0.2)
        }

        let depth = min(maxIndent, max(0, indent))
        var block = BlockStyle(listKind: listKind, alignment: alignment, indent: depth)
        if listKind != .none {
            block.alignment = .left
        }
        if block.listKind != .none {
            attrs[listKindKey] = block.listKind.rawValue
        }
        if block.alignment != .unspecified {
            attrs[alignmentKey] = block.alignment.rawValue
        }
        if block.indent > 0 {
            attrs[indentKey] = block.indent
        }

        if block.listKind != .none || block.alignment != .unspecified || block.indent > 0 {
            attrs[.paragraphStyle] = paragraphStyle(for: block)
        }
        return attrs
    }

    static func paragraphStyle(for block: BlockStyle) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let depth = min(maxIndent, max(0, block.indent))
        if block.listKind != .none {
            let levels = max(1, depth + 1)
            paragraph.textLists = (0..<levels).map { _ in
                NSTextList(markerFormat: block.listKind.markerFormat, options: 0)
            }
            paragraph.alignment = .left
            paragraph.headIndent = indentStep * CGFloat(levels)
            paragraph.firstLineHeadIndent = indentStep * CGFloat(levels - 1)
        } else {
            paragraph.alignment = block.alignment.nsTextAlignment
            paragraph.headIndent = indentStep * CGFloat(depth)
            paragraph.firstLineHeadIndent = indentStep * CGFloat(depth)
        }
        return paragraph
    }

    static func style(from attributes: [NSAttributedString.Key: Any]) -> Style {
        var style = Style()
        if let font = attributes[.font] as? Font {
            style.bold = isBold(font)
            style.italic = isItalic(font)
            style.code = isMonospaced(font)
        }
        if let underline = attributes[.underlineStyle] as? NSNumber, underline.intValue != 0 {
            style.underline = true
        }
        if let strike = attributes[.strikethroughStyle] as? NSNumber, strike.intValue != 0 {
            style.strike = true
        }
        if let offset = attributes[.baselineOffset] as? NSNumber {
            if offset.doubleValue > 0.5 { style.superscript = true }
            if offset.doubleValue < -0.5 { style.subscript = true }
        }
        if let hex = attributes[textColorHexKey] as? String, !hex.isEmpty {
            style.textColorHex = hex
        }
        if let hex = attributes[highlightHexKey] as? String, !hex.isEmpty {
            style.highlightHex = hex
        }
        if let href = attributes[linkHrefKey] as? String, !href.isEmpty {
            style.linkHref = href
        } else if let link = attributes[.link] as? String, !link.isEmpty {
            style.linkHref = link
        } else if let url = attributes[.link] as? URL {
            style.linkHref = url.absoluteString
        }
        return style
    }

    /// Hex (`#rrggbb` / `#rgb` / named subset) → platform color. Nil on
    /// unparseable input so callers fall back to the label color.
    // MARK: - HTML source IDE (highlight / match / auto-close / lines)

    /// Void elements that never get an auto-close tag.
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    ]

    /// Syntax-highlighted source attributed string (mono font): tags, attr
    /// names, quoted values, comments, and entities each get a dynamic
    /// system color so both appearances stay legible.
    static func highlightSource(_ source: String, font: Font) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source)
        let full = NSRange(location: 0, length: (source as NSString).length)
        guard full.length > 0 else { return result }
        result.addAttribute(.font, value: font, range: full)
        #if canImport(UIKit)
        let textColor = UIColor.label
        let tagColor = UIColor.systemBlue
        let attrColor = UIColor.systemTeal
        let stringColor = UIColor.systemBrown
        let commentColor = UIColor.systemGray
        let entityColor = UIColor.systemPurple
        #else
        let textColor = NSColor.labelColor
        let tagColor = NSColor.systemBlue
        let attrColor = NSColor.systemTeal
        let stringColor = NSColor.brown
        let commentColor = NSColor.systemGray
        let entityColor = NSColor.systemPurple
        #endif
        result.addAttribute(.foregroundColor, value: textColor, range: full)

        func paint(_ pattern: String, options: NSRegularExpression.Options = [], color: Any) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: source, range: full) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        // Comments first (highest precedence).
        paint(#"<!--.*?-->"#, options: [.dotMatchesLineSeparators], color: commentColor)
        // Entities.
        paint(#"&[a-zA-Z0-9#]+;"#, color: entityColor)
        // Quoted attribute values.
        paint(#""[^"\n]*"|'[^'\n]*'"#, color: stringColor)
        // Tag-name + brackets: `<`, `</`, name, `/`, `>`.
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"</?[a-zA-Z][a-zA-Z0-9-]*|/?>"#,
            options: []
        ) else { return result }
        tagRegex.enumerateMatches(in: source, range: full) { match, _, _ in
            guard let match else { return }
            let ns = source as NSString
            let token = ns.substring(with: match.range)
            // Skip tokens already claimed by comments is overkill at field
            // sizes; comments paint first but tag paint would overpaint. To
            // keep precedence correct, verify the token is not inside a comment.
            if insideComment(ns, index: match.range.location) { return }
            result.addAttribute(.foregroundColor, value: tagColor, range: match.range)
            _ = token
        }
        // Attribute names: word followed by `=` outside comments/strings.
        guard let attrRegex = try? NSRegularExpression(
            pattern: #"[a-zA-Z_:][a-zA-Z0-9_:.-]*(?=\s*=\s*["'])"#,
            options: []
        ) else { return result }
        attrRegex.enumerateMatches(in: source, range: full) { match, _, _ in
            guard let match else { return }
            let ns = source as NSString
            if insideComment(ns, index: match.range.location) { return }
            // Must sit inside a tag: nearest `<` ahead without an
            // intervening `>`.
            let prefix = ns.substring(to: match.range.location)
            guard let open = prefix.lastIndex(of: "<"),
                  !prefix[open...].contains(">") else { return }
            result.addAttribute(.foregroundColor, value: attrColor, range: match.range)
        }
        return result
    }

    private static func insideComment(_ ns: NSString, index: Int) -> Bool {
        let text = ns as String
        var cursor = text.startIndex
        while let open = text.range(of: "<!--", range: cursor..<text.endIndex) {
            guard let close = text.range(of: "-->", range: open.upperBound..<text.endIndex) else {
                // Unclosed comment runs to the end.
                return index >= text.distance(from: text.startIndex, to: open.lowerBound)
            }
            let openIdx = text.distance(from: text.startIndex, to: open.lowerBound)
            let closeIdx = text.distance(from: text.startIndex, to: close.upperBound)
            if index >= openIdx, index < closeIdx { return true }
            cursor = close.upperBound
        }
        return false
    }

    /// Line/column (1-based) of a character index for the status readout.
    static func lineColumn(in source: NSString, index: Int) -> (line: Int, column: Int) {
        let clamped = max(0, min(index, source.length))
        let prefix = source.substring(to: clamped)
        let line = prefix.components(separatedBy: "\n").count
        let lastBreak = prefix.lastIndex(of: "\n")
        let lineStart = lastBreak.map { prefix.distance(from: prefix.startIndex, to: $0) + 1 } ?? 0
        return (line, clamped - lineStart + 1)
    }

    /// 1-based line number gutter text (`"1\n2\n3…"`) for a source string.
    /// Counts real paragraphs (matching the gutter's fragment walk) plus the
    /// phantom line when the text ends with a newline.
    static func lineNumbers(for source: String) -> String {
        var count = 0
        (source as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (source as NSString).length),
            options: .byParagraphs
        ) { _, _, _, _ in count += 1 }
        if source.hasSuffix("\n") { count += 1 }
        count = max(1, count)
        return (1...count).map(String.init).joined(separator: "\n")
    }

    /// Matching open/close tag pair around `cursor` (either side inside the
    /// tag or its content). Nil for void elements, comments, and unmatched.
    static func matchingTagPair(in source: NSString, cursor: Int) -> (open: NSRange, close: NSRange)? {
        let text = source as String
        let full = NSRange(location: 0, length: source.length)
        guard full.length > 0 else { return nil }
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9-]*)[^<>]*?(/?)>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        struct Tag { let name: String; let range: NSRange; let isClose: Bool; let selfClose: Bool }
        var tags: [Tag] = []
        tagRegex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, match.range.location != NSNotFound else { return }
            let ns = text as NSString
            let token = ns.substring(with: match.range)
            if token.hasPrefix("<!--") { return }
            let nameRange = match.range(at: 2)
            guard nameRange.location != NSNotFound else { return }
            let name = ns.substring(with: nameRange).lowercased()
            let closeRange = match.range(at: 1)
            let selfRange = match.range(at: 3)
            let isClose = closeRange.location != NSNotFound
                && ns.substring(with: closeRange) == "/"
            let selfClose = selfRange.location != NSNotFound
                && !ns.substring(with: selfRange).isEmpty
            tags.append(Tag(name: name, range: match.range, isClose: isClose, selfClose: selfClose))
        }
        // Anchor: innermost tag containing the cursor, else the tag just before it.
        var anchor: Int?
        for (i, tag) in tags.enumerated() {
            if NSLocationInRange(cursor, tag.range)
                || (cursor == tag.range.location + tag.range.length && cursor > 0) {
                anchor = i
            }
        }
        if anchor == nil {
            for (i, tag) in tags.enumerated() where tag.range.location + tag.range.length <= cursor {
                anchor = i
            }
        }
        guard let a = anchor else { return nil }
        let pivot = tags[a]
        guard !pivot.selfClose, !voidElements.contains(pivot.name) else { return nil }
        if pivot.isClose {
            var depth = 0
            for i in stride(from: a, through: 0, by: -1) {
                let t = tags[i]
                guard t.name == pivot.name, !t.selfClose, !voidElements.contains(t.name) else { continue }
                if t.isClose { depth += 1 } else {
                    depth -= 1
                    if depth == 0 { return (t.range, pivot.range) }
                }
            }
        } else {
            var depth = 0
            for i in a..<tags.count {
                let t = tags[i]
                guard t.name == pivot.name, !t.selfClose, !voidElements.contains(t.name) else { continue }
                if !t.isClose { depth += 1 } else {
                    depth -= 1
                    if depth == 0 { return (pivot.range, t.range) }
                }
            }
        }
        return nil
    }

    /// Auto-close insertion for a just-typed `>` at `gtIndex` (the `>`'s own
    /// index). Returns the closing tag to insert, or nil for closing tags,
    /// self-closed tags, void elements, and non-tag `>` (e.g. math `a>b`).
    static func autoCloseTag(in source: NSString, gtIndex: Int) -> String? {
        guard gtIndex > 0, gtIndex <= source.length else { return nil }
        let text = source as String
        // Walk back over the tag body to its `<`.
        var i = gtIndex - 1
        let ns = text as NSString
        // `/` immediately before `>` means self-closed.
        if ns.character(at: i) == 47 { return nil } // "/"
        while i >= 0 {
            let ch = ns.character(at: i)
            if ch == 60 { break } // "<"
            if ch == 62 { return nil } // ">" — not inside a tag
            i -= 1
        }
        guard i >= 0 else { return nil }
        let body = ns.substring(with: NSRange(location: i + 1, length: gtIndex - i - 1))
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("!") else { return nil }
        let name = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map(String.init) ?? ""
        guard !name.isEmpty, !voidElements.contains(name.lowercased()) else { return nil }
        // Don't duplicate when the text right after already closes it.
        let rest = ns.substring(from: gtIndex)
        if rest.hasPrefix("</\(name)>") || rest.hasPrefix("</\(name.lowercased())>") { return nil }
        return "</\(name)>"
    }

    static func platformColor(hex: String?) -> Any? {
        guard var hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        let named: [String: String] = [
            "red": "ff0000", "green": "008000", "blue": "0000ff",
            "black": "000000", "white": "ffffff", "gray": "808080",
            "grey": "808080", "yellow": "ffff00", "orange": "ffa500",
            "purple": "800080", "pink": "ffc0cb",
        ]
        if let mapped = named[hex] { hex = mapped }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        #if canImport(UIKit)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
        #else
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #endif
    }

    /// Normalizes a CSS/HTML color to `#rrggbb` for round-tripping.
    static func normalizeHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            var hex = String(trimmed.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, UInt32(hex, radix: 16) != nil else { return nil }
            return "#" + hex
        }
        if trimmed.hasPrefix("rgb") { return nil }
        let named: [String: String] = [
            "red": "#ff0000", "green": "#008000", "blue": "#0000ff",
            "black": "#000000", "white": "#ffffff", "gray": "#808080",
            "grey": "#808080", "yellow": "#ffff00", "orange": "#ffa500",
            "purple": "#800080", "pink": "#ffc0cb",
        ]
        return named[trimmed]
    }

    static func fontByApplying(_ style: Style, to font: Font) -> Font {
        let pointSize = style.superscript || style.subscript ? font.pointSize * 0.75 : font.pointSize
        #if canImport(UIKit)
        if style.code {
            return UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        var traits = font.fontDescriptor.symbolicTraits
        if style.bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        if style.italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
            return font.withSize(pointSize)
        }
        return UIFont(descriptor: descriptor, size: pointSize)
        #else
        if style.code {
            return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        let manager = NSFontManager.shared
        var converted = font
        converted = manager.convert(
            converted,
            toHaveTrait: style.bold ? .boldFontMask : []
        )
        converted = manager.convert(
            converted,
            toNotHaveTrait: style.bold ? [] : .boldFontMask
        )
        converted = manager.convert(
            converted,
            toHaveTrait: style.italic ? .italicFontMask : []
        )
        converted = manager.convert(
            converted,
            toNotHaveTrait: style.italic ? [] : .italicFontMask
        )
        return manager.convert(converted, toSize: pointSize)
        #endif
    }

    // MARK: - Parse

    private static func parse(_ html: String, font: Font) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !html.isEmpty else { return result }

        var index = html.startIndex
        var style = Style()
        var stack: [Style] = []
        var block = BlockStyle()
        var blockStack: [BlockStyle] = []

        func append(_ text: String) {
            let decoded = decodeEntities(text).replacingOccurrences(of: zeroWidthSpace, with: "")
            guard !decoded.isEmpty else { return }
            result.append(NSAttributedString(
                string: decoded,
                attributes: attributes(for: style, font: font, block: block)
            ))
        }

        func appendBreak() {
            result.append(NSAttributedString(
                string: "\n",
                attributes: attributes(for: style, font: font, block: block)
            ))
        }

        while index < html.endIndex {
            if html[index] == "<" {
                guard let close = html[index...].firstIndex(of: ">") else {
                    append(String(html[index...]))
                    break
                }
                let tagBody = String(html[html.index(after: index)..<close])
                if let info = imageInfo(from: tagBody) {
                    result.append(imagePlaceholder(
                        filename: info.filename, font: font, style: style, block: block,
                        widthAttr: info.width, heightAttr: info.height
                    ))
                    index = html.index(after: close)
                    continue
                }
                switch apply(
                    tag: tagBody,
                    style: &style,
                    stack: &stack,
                    block: &block,
                    blockStack: &blockStack
                ) {
                case .none:
                    break
                case .lineBreak:
                    appendBreak()
                case .blockOpen:
                    if result.length > 0,
                       (result.string as NSString).character(at: result.length - 1) != 10
                    {
                        appendBreak()
                    }
                }
                index = html.index(after: close)
            } else {
                let nextTag = html[index...].firstIndex(of: "<") ?? html.endIndex
                append(String(html[index..<nextTag]))
                index = nextTag
            }
        }

        while result.length > 0,
              (result.string as NSString).character(at: result.length - 1) == 10
        {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private enum TagEffect {
        case none
        case lineBreak
        case blockOpen
    }

    private static func apply(
        tag raw: String,
        style: inout Style,
        stack: inout [Style],
        block: inout BlockStyle,
        blockStack: inout [BlockStyle]
    ) -> TagEffect {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("!") else { return .none }

        let isClose = trimmed.hasPrefix("/")
        let nameAndRest = isClose ? String(trimmed.dropFirst()) : trimmed
        let name = nameAndRest
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        let isEmpty = trimmed.hasSuffix("/") || name == "br"
        let attrs = tagAttributes(nameAndRest)

        switch (isClose, isEmpty, name) {
        case (_, true, "br"), (false, _, "br"):
            return .lineBreak
        case (false, _, "ul"), (false, _, "ol"):
            blockStack.append(block)
            let parsed = listKind(from: attrs, ordered: name == "ol")
            block.listKind = parsed
            block.alignment = .left
            if let parentList = blockStack.last?.listKind, parentList != .none {
                block.indent = min(maxIndent, block.indent + 1)
            }
        case (true, _, "ul"), (true, _, "ol"):
            block = blockStack.popLast() ?? BlockStyle()
        case (true, _, "div"), (true, _, "p"), (true, _, "li"),
             (true, _, "h1"), (true, _, "h2"), (true, _, "h3"),
             (true, _, "h4"), (true, _, "h5"), (true, _, "h6"):
            if name != "li" {
                block.alignment = blockStack.last?.alignment ?? .unspecified
                if name == "div" || name == "p" {
                    block.indent = blockStack.last?.indent ?? block.indent
                }
            }
            return .lineBreak
        case (false, _, "div"), (false, _, "p"):
            blockStack.append(block)
            if let alignment = alignment(from: attrs) {
                block.alignment = alignment
            }
            if let margin = marginLeft(from: attrs) {
                block.indent = min(maxIndent, Int((margin / indentStep).rounded()))
            }
            return .blockOpen
        case (false, _, "li"),
             (false, _, "h1"), (false, _, "h2"), (false, _, "h3"),
             (false, _, "h4"), (false, _, "h5"), (false, _, "h6"):
            return .blockOpen
        case (false, _, "b"), (false, _, "strong"):
            stack.append(style)
            style.bold = true
        case (false, _, "i"), (false, _, "em"):
            stack.append(style)
            style.italic = true
        case (false, _, "u"):
            stack.append(style)
            style.underline = true
        case (false, _, "s"), (false, _, "strike"), (false, _, "del"):
            stack.append(style)
            style.strike = true
        case (false, _, "sup"):
            stack.append(style)
            style.superscript = true
            style.subscript = false
        case (false, _, "sub"):
            stack.append(style)
            style.subscript = true
            style.superscript = false
        case (false, _, "code"):
            stack.append(style)
            style.code = true
        case (true, _, "b"), (true, _, "strong"),
             (true, _, "i"), (true, _, "em"),
             (true, _, "u"),
             (true, _, "s"), (true, _, "strike"), (true, _, "del"),
             (true, _, "sup"), (true, _, "sub"), (true, _, "code"),
             (true, _, "a"), (true, _, "span"), (true, _, "font"):
            style = stack.popLast() ?? Style()
        case (false, _, "a"):
            stack.append(style)
            if let href = attrs["href"], !href.isEmpty {
                style.linkHref = href
            }
        case (false, _, "font"):
            stack.append(style)
            if let color = attrs["color"], let hex = normalizeHex(color) {
                style.textColorHex = hex
            }
        case (false, _, "span"):
            stack.append(style)
            if let css = attrs["style"] {
                let map = cssMap(css)
                if let color = map["color"], let hex = normalizeHex(color) {
                    style.textColorHex = hex
                }
                if let bg = map["background-color"] ?? map["background"],
                   let hex = normalizeHex(bg) {
                    style.highlightHex = hex
                }
            }
        default:
            break
        }
        return .none
    }

    // MARK: - Encode

    private static func encodeRuns(_ attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var output = ""
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            if let filename = imageFilename(from: attributes), !filename.isEmpty {
                var tag = #"<img src="\#(escapeAttribute(filename))""#
                if let attachment = attributes[.attachment] as? NoteFieldImageAttachment {
                    if let w = attachment.widthAttr, !w.isEmpty {
                        tag += #" width="\#(escapeAttribute(w))""#
                    }
                    if let h = attachment.heightAttr, !h.isEmpty {
                        tag += #" height="\#(escapeAttribute(h))""#
                    }
                }
                tag += ">"
                output += tag
                return
            }
            let raw = (attributed.string as NSString).substring(with: subrange)
            let escaped = escapeTextPreservingBreaks(raw)
            output += wrap(escaped, style: style(from: attributes))
        }
        return output
    }

    private static func wrap(_ text: String, style: Style) -> String {
        guard !text.isEmpty else { return "" }
        var wrapped = text
        if style.code { wrapped = "<code>\(wrapped)</code>" }
        if style.subscript { wrapped = "<sub>\(wrapped)</sub>" }
        if style.superscript { wrapped = "<sup>\(wrapped)</sup>" }
        if style.strike { wrapped = "<s>\(wrapped)</s>" }
        if style.underline { wrapped = "<u>\(wrapped)</u>" }
        if style.italic { wrapped = "<i>\(wrapped)</i>" }
        if style.bold { wrapped = "<b>\(wrapped)</b>" }
        // Colors/links wrap last (outermost) so inner tags stay intact.
        var css = ""
        if let c = style.textColorHex { css += "color: \(c);" }
        if let h = style.highlightHex { css += "background-color: \(h);" }
        if !css.isEmpty {
            wrapped = "<span style=\"\(css.trimmingCharacters(in: .whitespaces))\">\(wrapped)</span>"
        }
        if let href = style.linkHref, !href.isEmpty {
            wrapped = "<a href=\"\(escapeAttribute(href))\">\(wrapped)</a>"
        }
        return wrapped
    }

    /// Image tag info: filename plus author-specified dimensions (width /
    /// height attributes or inline `style="width:…;height:…"`), preserved
    /// through the rich round-trip instead of discarded.
    struct ImageTagInfo {
        let filename: String
        let width: String?
        let height: String?
    }

    private static func imageInfo(from tag: String) -> ImageTagInfo? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("img") else { return nil }
        let attrs = tagAttributes(trimmed)
        guard let src = attrs["src"], !src.isEmpty else { return nil }
        var width = attrs["width"]
        var height = attrs["height"]
        if let style = attrs["style"] {
            let css = cssMap(style)
            width = width ?? css["width"]
            height = height ?? css["height"]
        }
        return ImageTagInfo(filename: src, width: width, height: height)
    }

    private static func imageSource(from tag: String) -> String? {
        imageInfo(from: tag)?.filename
    }

    static func imageFilename(from attributes: [NSAttributedString.Key: Any]) -> String? {
        if let filename = attributes[imageFilenameKey] as? String, !filename.isEmpty {
            return filename
        }
        if let attachment = attributes[.attachment] as? NoteFieldImageAttachment,
           !attachment.filename.isEmpty
        {
            return attachment.filename
        }
        if let attachment = attributes[.attachment] as? NSTextAttachment,
           let filename = attachment.fileWrapper?.preferredFilename,
           !filename.isEmpty
        {
            return filename
        }
        return nil
    }

    private static func escapeAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    static func imagePlaceholder(
        filename: String,
        font: Font,
        style: Style = .init(),
        listKind: ListKind = .none,
        block: BlockStyle? = nil,
        image: PlatformImage? = nil,
        widthAttr: String? = nil,
        heightAttr: String? = nil
    ) -> NSAttributedString {
        let attachment = NoteFieldImageAttachment(filename: filename)
        attachment.image = framedImage(image) ?? loadingPlaceholderImage()
        attachment.widthAttr = widthAttr
        attachment.heightAttr = heightAttr
        var attrs = attributes(for: style, font: font, block: block ?? BlockStyle(listKind: listKind))
        attrs[imageFilenameKey] = filename
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attrs, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Info about the image attachment at `index` (the tapped glyph), for
    /// the resize menu. Nil when the index is not on an image.
    static func imageInfo(
        in attributed: NSAttributedString,
        at index: Int
    ) -> (filename: String, width: String?, height: String?)? {
        guard index >= 0, index < attributed.length else { return nil }
        var result: (String, String?, String?)?
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: index, length: 1),
            options: []
        ) { value, _, _ in
            guard let attachment = value as? NoteFieldImageAttachment else { return }
            result = (attachment.filename, attachment.widthAttr, attachment.heightAttr)
        }
        return result
    }

    /// Sets (`width` px, height auto) or clears (nil) the stored dimensions
    /// of the image attachment at `index`. Returns false when no attachment
    /// was found there. Operates on the attachment object in place so the
    /// text layout is untouched — the next encode re-emits the tag.
    @discardableResult
    static func setImageWidth(
        _ width: String?,
        in attributed: NSAttributedString,
        at index: Int
    ) -> Bool {
        guard index >= 0, index < attributed.length else { return false }
        var applied = false
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: index, length: 1),
            options: []
        ) { value, _, _ in
            guard let attachment = value as? NoteFieldImageAttachment else { return }
            attachment.widthAttr = width
            attachment.heightAttr = nil
            applied = true
        }
        return applied
    }

    static func framedImage(_ image: PlatformImage?) -> PlatformImage? {
        guard let image else { return nil }
        let radius: CGFloat = 14
        #if canImport(UIKit)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            image.draw(in: rect)
        }
        #else
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let framed = NSImage(size: size)
        framed.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).addClip()
        image.draw(in: NSRect(origin: .zero, size: size))
        framed.unlockFocus()
        return framed
        #endif
    }

    private static func loadingPlaceholderImage() -> PlatformImage {
        let size = CGSize(width: 280, height: 196)
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 14)
            UIColor.secondarySystemFill.setFill()
            path.fill()
        }
        #else
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
        image.unlockFocus()
        return image
        #endif
    }

    private static func escapeTextPreservingBreaks(_ text: String) -> String {
        text
            .replacingOccurrences(of: zeroWidthSpace, with: "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func trimMathJaxBreaks(in text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<br[ ]*/?>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"^\n*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n*$"#, with: "", options: .regularExpression)
    }

    private static var labelColor: Any {
        #if canImport(UIKit)
        UIColor.label
        #else
        NSColor.labelColor
        #endif
    }

    private static func isBold(_ font: Font) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #else
        NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        #endif
    }

    private static func isMonospaced(_ font: Font) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #else
        NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
        #endif
    }

    private static func isItalic(_ font: Font) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
        NSFontManager.shared.traits(of: font).contains(.italicFontMask)
        #endif
    }

    private static func tagAttributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = tag as NSString
        let regex = try? NSRegularExpression(
            pattern: #"([a-zA-Z:-]+)\s*=\s*["']([^"']*)["']"#,
            options: []
        )
        regex?.enumerateMatches(in: tag, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 2 else { return }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            result[key] = ns.substring(with: match.range(at: 2))
        }
        return result
    }

    private static func cssMap(_ style: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in style.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pair[1].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return result
    }

    private static func alignment(from attrs: [String: String]) -> Alignment? {
        if let align = attrs["align"] {
            return alignmentValue(align)
        }
        if let style = attrs["style"] {
            return alignmentValue(cssMap(style)["text-align"] ?? "")
        }
        return nil
    }

    private static func alignmentValue(_ raw: String) -> Alignment? {
        switch raw.lowercased() {
        case "left", "start": .left
        case "center": .center
        case "right", "end": .right
        default: nil
        }
    }

    private static func marginLeft(from attrs: [String: String]) -> CGFloat? {
        guard let style = attrs["style"] else { return nil }
        let css = cssMap(style)
        guard let raw = css["margin-left"] ?? css["padding-left"] else { return nil }
        let number = raw.replacingOccurrences(of: "px", with: "")
        return Double(number).map { CGFloat($0) }
    }

    private static func listKind(from attrs: [String: String], ordered: Bool) -> ListKind {
        if let type = attrs["type"], let parsed = ListKind.fromCSS(type) {
            return parsed
        }
        if let style = attrs["style"], let type = cssMap(style)["list-style-type"], let parsed = ListKind.fromCSS(type) {
            return parsed
        }
        return ordered ? .numbered : .bullet
    }

    static func toggleListKind(
        on attributed: NSMutableAttributedString,
        range: NSRange,
        kind: ListKind,
        font: Font
    ) -> NSRange {
        ensureEditableParagraph(in: attributed, font: font)
        let ns = attributed.string as NSString
        let safeLocation = min(max(0, range.location), attributed.length)
        let full = range.length == 0
            ? ns.paragraphRange(for: NSRange(location: min(safeLocation, max(0, attributed.length - 1)), length: 0))
            : ns.paragraphRange(for: NSRange(location: range.location, length: min(range.length, attributed.length - range.location)))
        let current = blockStyle(in: attributed, at: full.location).listKind
        let target: ListKind = current == kind ? .none : kind
        applyBlock(on: attributed, range: full, font: font) { block in
            block.listKind = target
            if target != .none {
                block.alignment = .left
            }
        }
        let caret = min(range.location, attributed.length)
        return NSRange(location: caret, length: 0)
    }

    static func applyAlignment(
        on attributed: NSMutableAttributedString,
        range: NSRange,
        alignment: Alignment,
        font: Font
    ) {
        ensureEditableParagraph(in: attributed, font: font)
        applyBlock(on: attributed, range: paragraphRange(in: attributed, range: range), font: font) { block in
            if block.listKind != .none {
                block.alignment = .left
            } else {
                block.alignment = alignment
            }
        }
    }

    static func changeIndent(
        on attributed: NSMutableAttributedString,
        range: NSRange,
        delta: Int,
        font: Font
    ) {
        ensureEditableParagraph(in: attributed, font: font)
        applyBlock(on: attributed, range: paragraphRange(in: attributed, range: range), font: font) { block in
            block.indent = min(maxIndent, max(0, block.indent + delta))
        }
    }

    /// Return-key behaviour inside a list: empty item outdents/exits; otherwise
    /// a new item is created with the same style. Returns nil to use the system insert.
    static func handleReturn(
        on attributed: NSMutableAttributedString,
        range: NSRange,
        font: Font
    ) -> NSRange? {
        guard attributed.length > 0 else { return nil }
        let ns = attributed.string as NSString
        let location = min(range.location, attributed.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: min(location, max(0, attributed.length - 1)), length: 0))
        let block = blockStyle(in: attributed, at: paragraph.location)
        guard block.listKind != .none else { return nil }

        var content = paragraph
        if paragraph.length > 0, ns.character(at: paragraph.location + paragraph.length - 1) == 10 {
            content.length -= 1
        }
        let item = ns.substring(with: content)
            .replacingOccurrences(of: zeroWidthSpace, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if item.isEmpty {
            applyBlock(on: attributed, range: paragraph, font: font) { current in
                if current.indent > 0 {
                    current.indent -= 1
                } else {
                    current.listKind = .none
                    current.alignment = .unspecified
                }
            }
            return NSRange(location: min(range.location, attributed.length), length: 0)
        }

        let insertion = NSAttributedString(
            string: "\n" + zeroWidthSpace,
            attributes: attributes(for: style(from: attributed.attributes(at: min(location, attributed.length - 1), effectiveRange: nil)), font: font, block: block)
        )
        attributed.replaceCharacters(in: range, with: insertion)
        return NSRange(location: range.location + insertion.length, length: 0)
    }

    private static func paragraphRange(in attributed: NSAttributedString, range: NSRange) -> NSRange {
        let ns = attributed.string as NSString
        guard attributed.length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, range.location), attributed.length - 1)
        if range.length == 0 {
            return ns.paragraphRange(for: NSRange(location: location, length: 0))
        }
        return ns.paragraphRange(for: NSRange(location: range.location, length: min(range.length, attributed.length - range.location)))
    }

    private static func ensureEditableParagraph(in attributed: NSMutableAttributedString, font: Font) {
        if attributed.length == 0 {
            attributed.append(NSAttributedString(
                string: zeroWidthSpace,
                attributes: attributes(for: .init(), font: font)
            ))
        }
    }

    private static func applyBlock(
        on attributed: NSMutableAttributedString,
        range: NSRange,
        font: Font,
        update: (inout BlockStyle) -> Void
    ) {
        guard attributed.length > 0 else { return }
        let target = range.length == 0 ? NSRange(location: 0, length: attributed.length) : range
        var location = target.location
        let end = min(attributed.length, target.location + max(target.length, 1))
        let ns = attributed.string as NSString
        while location < end {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var replacements: [(NSRange, [NSAttributedString.Key: Any])] = []
            let enumerateRange = paragraph.length == 0
                ? NSRange(location: 0, length: attributed.length)
                : paragraph
            attributed.enumerateAttributes(in: enumerateRange, options: []) { attributes, subrange, _ in
                let resolved = style(from: attributes)
                var block = blockStyle(from: attributes)
                update(&block)
                var next = self.attributes(for: resolved, font: font, block: block)
                if let filename = attributes[imageFilenameKey] {
                    next[imageFilenameKey] = filename
                }
                if let attachment = attributes[.attachment] {
                    next[.attachment] = attachment
                }
                replacements.append((subrange, next))
            }
            for (subrange, next) in replacements {
                attributed.setAttributes(next, range: subrange)
            }
            location = paragraph.location + max(paragraph.length, 1)
            if paragraph.length == 0 { break }
        }
    }
}

/// Attachment that keeps the Anki media filename even if UIKit drops custom
/// attributes, and sizes the bitmap to the field width.
final class NoteFieldImageAttachment: NSTextAttachment {
    var filename: String
    /// Author-specified dimensions from the source `<img>` tag, re-emitted
    /// on encode so the rich round-trip preserves them.
    var widthAttr: String?
    var heightAttr: String?

    init(filename: String) {
        self.filename = filename
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        filename = (coder.decodeObject(of: NSString.self, forKey: "amgi.filename") as String?) ?? ""
        widthAttr = coder.decodeObject(of: NSString.self, forKey: "amgi.width") as String?
        heightAttr = coder.decodeObject(of: NSString.self, forKey: "amgi.height") as String?
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(filename as NSString, forKey: "amgi.filename")
        if let widthAttr { coder.encode(widthAttr as NSString, forKey: "amgi.width") }
        if let heightAttr { coder.encode(heightAttr as NSString, forKey: "amgi.height") }
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let maxWidth = max(96, lineFrag.width > 8 ? lineFrag.width - 8 : 280)
        let maxHeight: CGFloat = 420
        #if canImport(UIKit)
        let size = image?.size ?? CGSize(width: maxWidth, height: min(maxWidth * 0.7, 200))
        #else
        let size = image?.size ?? NSSize(width: maxWidth, height: min(maxWidth * 0.7, 200))
        #endif
        guard size.width > 0, size.height > 0 else {
            return CGRect(x: 0, y: 0, width: maxWidth, height: 160)
        }
        let scale = min(1, maxWidth / size.width, maxHeight / size.height)
        return CGRect(
            x: 0,
            y: 0,
            width: floor(size.width * scale),
            height: floor(size.height * scale)
        )
    }
}
