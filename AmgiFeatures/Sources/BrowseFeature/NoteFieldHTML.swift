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
    }

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
                if let filename = imageSource(from: tagBody) {
                    result.append(imagePlaceholder(filename: filename, font: font, style: style, block: block))
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
            if !blockStack.isEmpty, blockStack.last?.listKind != .none {
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
            if let filename = imageFilename(from: attributes), !filename.isEmpty {
                output += #"<img src="\#(escapeAttribute(filename))">"#
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
        image: PlatformImage? = nil
    ) -> NSAttributedString {
        let attachment = NoteFieldImageAttachment(filename: filename)
        attachment.image = framedImage(image) ?? loadingPlaceholderImage()
        var attrs = attributes(for: style, font: font, block: block ?? BlockStyle(listKind: listKind))
        attrs[imageFilenameKey] = filename
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attrs, range: NSRange(location: 0, length: result.length))
        return result
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

    init(filename: String) {
        self.filename = filename
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        filename = (coder.decodeObject(of: NSString.self, forKey: "amgi.filename") as String?) ?? ""
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(filename as NSString, forKey: "amgi.filename")
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
