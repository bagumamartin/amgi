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
    #else
    typealias Font = NSFont
    #endif

    enum ListKind: Int, Equatable, Sendable {
        case none = 0
        case bullet = 1
        case numbered = 2
    }

    static let listKindKey = NSAttributedString.Key("amgi.noteField.listKind")
    static let imageFilenameKey = NSAttributedString.Key("amgi.noteField.imageFilename")

    struct Style: Equatable, Sendable {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var superscript = false
        var `subscript` = false
        var code = false
    }

    static func defaultFont() -> Font {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body)
        #else
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #endif
    }

    /// Decode stored field HTML into attributed text for the editor.
    static func attributedString(
        from html: String,
        font: Font = defaultFont()
    ) -> NSAttributedString {
        parse(normalizeMathJax(html), font: font)
    }

    /// Encode editor attributed text back into Anki field HTML.
    static func encode(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }

        var output = ""
        var openList: ListKind = .none
        let ns = attributed.string as NSString
        var location = 0

        func closeList() {
            switch openList {
            case .bullet: output += "</ul>"
            case .numbered: output += "</ol>"
            case .none: break
            }
            openList = .none
        }

        while location < attributed.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            if paragraph.length > 0, ns.character(at: paragraph.location + paragraph.length - 1) == 10 {
                content.length -= 1
            }
            let kind = listKind(in: attributed, at: paragraph.location)
            if kind != openList {
                closeList()
                switch kind {
                case .bullet: output += "<ul>"
                case .numbered: output += "<ol>"
                case .none: break
                }
                openList = kind
            }
            let encoded = encodeRuns(attributed, range: content)
            if kind == .none {
                output += encoded
                if paragraph.location + paragraph.length < attributed.length {
                    output += "<br>"
                }
            } else {
                output += "<li>\(encoded)</li>"
            }
            location = paragraph.location + paragraph.length
        }
        closeList()
        return output
    }

    static func listKind(in attributed: NSAttributedString, at location: Int) -> ListKind {
        guard attributed.length > 0 else { return .none }
        let loc = min(max(0, location), attributed.length - 1)
        let raw = attributed.attributes(at: loc, effectiveRange: nil)[listKindKey] as? Int
        return ListKind(rawValue: raw ?? 0) ?? .none
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

    /// Round-trip helper used by tests: HTML → attributes → HTML.
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

    static func attributes(for style: Style, font: Font, listKind: ListKind = .none) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fontByApplying(style, to: font),
            .foregroundColor: labelColor,
        ]
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
        if listKind != .none {
            attrs[listKindKey] = listKind.rawValue
            let paragraph = NSMutableParagraphStyle()
            let format: NSTextList.MarkerFormat = listKind == .numbered ? .decimal : .disc
            paragraph.textLists = [NSTextList(markerFormat: format, options: 0)]
            paragraph.headIndent = 28
            paragraph.firstLineHeadIndent = 28
            attrs[.paragraphStyle] = paragraph
        }
        return attrs
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
        return style
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
        var listKind: ListKind = .none
        var listStack: [ListKind] = []

        func append(_ text: String) {
            let decoded = decodeEntities(text)
            guard !decoded.isEmpty else { return }
            result.append(NSAttributedString(
                string: decoded,
                attributes: attributes(for: style, font: font, listKind: listKind)
            ))
        }

        func appendBreak() {
            result.append(NSAttributedString(
                string: "\n",
                attributes: attributes(for: style, font: font, listKind: listKind)
            ))
        }

        while index < html.endIndex {
            if html[index] == "<" {
                guard let close = html[index...].firstIndex(of: ">") else {
                    append(String(html[index...]))
                    break
                }
                let tagBody = String(html[html.index(after: index)..<close])
                if let filename = imageSource(from: tagBody) {
                    result.append(imagePlaceholder(filename: filename, font: font, style: style, listKind: listKind))
                    index = html.index(after: close)
                    continue
                }
                switch apply(tag: tagBody, style: &style, stack: &stack, listKind: &listKind, listStack: &listStack) {
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
        listKind: inout ListKind,
        listStack: inout [ListKind]
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

        switch (isClose, isEmpty, name) {
        case (_, true, "br"), (false, _, "br"):
            return .lineBreak
        case (false, _, "ul"):
            listStack.append(listKind)
            listKind = .bullet
        case (false, _, "ol"):
            listStack.append(listKind)
            listKind = .numbered
        case (true, _, "ul"), (true, _, "ol"):
            listKind = listStack.popLast() ?? .none
        case (true, _, "div"), (true, _, "p"), (true, _, "li"),
             (true, _, "h1"), (true, _, "h2"), (true, _, "h3"),
             (true, _, "h4"), (true, _, "h5"), (true, _, "h6"):
            return .lineBreak
        case (false, _, "div"), (false, _, "p"), (false, _, "li"),
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
             (true, _, "sup"), (true, _, "sub"), (true, _, "code"):
            style = stack.popLast() ?? Style()
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
            if let filename = attributes[imageFilenameKey] as? String, !filename.isEmpty {
                output += #"<img src="\#(filename)">"#
                return
            }
            if attributes[.attachment] != nil,
               let filename = String(data: (attributes[.attachment] as? NSTextAttachment)?.contents ?? Data(), encoding: .utf8),
               !filename.isEmpty
            {
                output += #"<img src="\#(filename)">"#
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
        return wrapped
    }

    private static func imageSource(from tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("img") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"src\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) else {
            return nil
        }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func imagePlaceholder(
        filename: String,
        font: Font,
        style: Style = .init(),
        listKind: ListKind = .none
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.contents = filename.data(using: .utf8)
        attachment.bounds = CGRect(x: 0, y: -4, width: font.pointSize * 1.4, height: font.pointSize * 1.4)
        #if canImport(UIKit)
        attachment.image = UIImage(systemName: "photo")
        #else
        attachment.image = NSImage(systemSymbolName: "photo", accessibilityDescription: filename)
        #endif
        var attrs = attributes(for: style, font: font, listKind: listKind)
        attrs[imageFilenameKey] = filename
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attrs, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func escapeTextPreservingBreaks(_ text: String) -> String {
        text
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

    static func toggleListKind(
        on attributed: NSMutableAttributedString,
        range: NSRange,
        kind: ListKind,
        font: Font
    ) {
        let ns = attributed.string as NSString
        let full = range.length == 0
            ? ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            : ns.paragraphRange(for: range)
        let current = listKind(in: attributed, at: full.location)
        let target: ListKind = current == kind ? .none : kind
        var location = full.location
        while location < full.location + full.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var replacements: [(NSRange, [NSAttributedString.Key: Any])] = []
            attributed.enumerateAttributes(in: paragraph, options: []) { attributes, subrange, _ in
                let resolved = style(from: attributes)
                var next = attributes
                for (key, value) in self.attributes(for: resolved, font: font, listKind: target) {
                    next[key] = value
                }
                if target == .none {
                    next[listKindKey] = nil
                    next[.paragraphStyle] = nil
                }
                replacements.append((subrange, next))
            }
            for (subrange, next) in replacements {
                attributed.setAttributes(next, range: subrange)
            }
            location = paragraph.location + paragraph.length
        }
    }

    private static func isItalic(_ font: Font) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
        NSFontManager.shared.traits(of: font).contains(.italicFontMask)
        #endif
    }
}
