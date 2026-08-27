public import Foundation

/// Structured content for the native card renderer (R11): the rendered HTML
/// of an allowlist-simple card reduced to display blocks plus extracted audio
/// file references. `CardComplexity` gates entry, so the parser only ever
/// sees tags it understands; anything unrecognized is stripped.
public struct NativeCardContent: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        case text(AttributedString)
        case image(filename: String)
        case divider
    }

    public let blocks: [Block]
    public let audioFiles: [String]

    public init(blocks: [Block], audioFiles: [String]) {
        self.blocks = blocks
        self.audioFiles = audioFiles
    }

    // MARK: - Answer-side split

    public var hasDivider: Bool {
        blocks.contains { block in
            if case .divider = block { return true }
            return false
        }
    }

    /// Concatenated plain text of all text blocks (images/dividers skipped),
    /// whitespace-normalized.
    var normalizedPlainText: String {
        Self.normalize(blocks.compactMap { block in
            if case .text(let attributed) = block { return String(attributed.characters) }
            return nil
        }.joined(separator: " "))
    }

    /// Returns this side restructured so the `{{FrontSide}}` recap and the
    /// answer are separated by a real `.divider` block, plus the index of the
    /// first answer block.
    ///
    /// - A real `<hr>` in the template is authoritative.
    /// - Without one, the front side's normalized plain text is matched as a
    ///   prefix of this side's text — the `{{FrontSide}}` expansion IS the
    ///   front HTML — and the divider is synthesized at the exact character
    ///   where the front text ends. Templates that glue recap and answer into
    ///   one block (separated only by raw newlines, which are not block
    ///   boundaries) get their text block SPLIT mid-stream; otherwise the
    ///   whole side would inherit recap styling.
    /// - When no reliable split exists (front text empty, or the back
    ///   diverges from the front), returns self with a nil answer start: the
    ///   whole side renders as answer.
    public func resolvingBackAnswerSplit(front: NativeCardContent) -> (content: NativeCardContent, answerStart: Int?) {
        if let dividerIndex = blocks.firstIndex(where: { block in
            if case .divider = block { return true }
            return false
        }) {
            return (self, dividerIndex + 1)
        }

        let frontText = front.normalizedPlainText
        guard !frontText.isEmpty else { return (self, nil) }

        var remaining = Substring(frontText)

        for (index, block) in blocks.enumerated() {
            guard case .text(let attributed) = block else { continue }
            let normalized = Self.normalize(String(attributed.characters))
            if normalized.isEmpty { continue }

            // Front text already fully covered by earlier blocks: everything
            // from here on is answer.
            if remaining.isEmpty {
                return (insertingDivider(at: index), index + 1)
            }

            // The front text ends inside (or exactly at the end of) this
            // block: split it at the character boundary.
            if normalized.hasPrefix(remaining) {
                let offset = Self.offset(
                    afterConsuming: remaining.count,
                    in: String(attributed.characters)
                )
                return (splittingBlock(at: index, offset: offset), index + 2)
            }

            // The whole block is recap; keep consuming the front text.
            guard remaining.hasPrefix(normalized) else {
                // Back text diverges from the front — no reliable split.
                return (self, nil)
            }
            remaining = Substring(Self.normalize(String(remaining.dropFirst(normalized.count))))
        }

        // Front text never fully matched (back is recap-only or divergent).
        return (self, nil)
    }

    private func insertingDivider(at index: Int) -> NativeCardContent {
        var newBlocks = blocks
        newBlocks.insert(.divider, at: index)
        return NativeCardContent(blocks: newBlocks, audioFiles: audioFiles)
    }

    /// Splits the text block at `index` into `[recap, .divider, answer]` at
    /// the given character offset. Whitespace at the seam is discarded. When
    /// the answer side reduces to nothing (the front ends at the block's
    /// end), only a divider is appended after the block.
    private func splittingBlock(at index: Int, offset: Int) -> NativeCardContent {
        guard case .text(let attributed) = blocks[index] else { return self }
        let characters = attributed.characters
        let splitIndex = characters.index(
            characters.startIndex,
            offsetBy: offset,
            limitedBy: characters.endIndex
        ) ?? characters.endIndex

        // Trim trailing whitespace off the recap slice.
        var recapEnd = splitIndex
        while recapEnd > characters.startIndex,
              characters[characters.index(before: recapEnd)].isWhitespace {
            recapEnd = characters.index(before: recapEnd)
        }
        // Skip leading whitespace off the answer slice.
        var answerStart = splitIndex
        while answerStart < characters.endIndex, characters[answerStart].isWhitespace {
            answerStart = characters.index(after: answerStart)
        }

        var newBlocks = blocks
        if answerStart >= characters.endIndex {
            newBlocks[index] = .text(AttributedString(attributed[characters.startIndex..<recapEnd]))
            newBlocks.insert(.divider, at: index + 1)
        } else {
            newBlocks.replaceSubrange(
                index...index,
                with: [
                    .text(AttributedString(attributed[characters.startIndex..<recapEnd])),
                    .divider,
                    .text(AttributedString(attributed[answerStart...])),
                ]
            )
        }
        return NativeCardContent(blocks: newBlocks, audioFiles: audioFiles)
    }

    /// Character offset in `original` right after its first `count`
    /// whitespace-collapsed characters — i.e. the recap/answer boundary
    /// within one block. Whitespace runs collapse to nothing here; the
    /// caller trims the seam.
    private static func offset(afterConsuming count: Int, in original: String) -> Int {
        var normalizedCount = 0
        var pendingSpace = false
        var offset = 0
        for character in original {
            if character.isWhitespace {
                if normalizedCount > 0 { pendingSpace = true }
            } else {
                if pendingSpace {
                    normalizedCount += 1
                    pendingSpace = false
                }
                normalizedCount += 1
                if normalizedCount >= count {
                    return offset + 1
                }
            }
            offset += 1
        }
        return offset
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func parse(html: String) -> NativeCardContent {
        var audioFiles: [String] = []
        let withoutSound = soundRegex.replacing(in: html) { match in
            audioFiles.append(match)
            return ""
        }

        var blocks: [Block] = []
        let ns = withoutSound as NSString
        var cursor = 0

        func flushText(upTo location: Int) {
            let raw = ns.substring(with: NSRange(location: cursor, length: location - cursor))
            if let text = parseInlineText(raw) {
                blocks.append(.text(text))
            }
        }

        for match in boundaryRegex.matches(in: withoutSound, range: NSRange(location: 0, length: ns.length)) {
            flushText(upTo: match.range.location)
            cursor = match.range.location + match.range.length

            let rawTag = ns.substring(with: match.range)
            let tag = rawTag.lowercased()
            if tag.hasPrefix("<hr") {
                blocks.append(.divider)
            } else if tag.hasPrefix("<img") {
                if let src = imageSource(in: rawTag) {
                    blocks.append(.image(filename: src))
                }
            }
            // <br>, </div>, </p>, </center> are pure separators.
        }
        flushText(upTo: ns.length)

        return NativeCardContent(blocks: blocks, audioFiles: audioFiles)
    }

    // MARK: - Regexes

    private static let soundRegex = try! NSRegularExpression(pattern: #"\[sound:([^\]]+)\]"#)

    /// Block boundaries: standalone blocks (`<hr>`, `<img>`) and separators.
    private static let boundaryRegex = try! NSRegularExpression(
        pattern: #"<hr\s*/?>|<img\b[^>]*>|<br\s*/?>|</div>|</p>|</center>"#,
        options: [.caseInsensitive]
    )

    /// Inline emphasis tags handled during text-run construction.
    /// (`<u>` is allowlisted but renders plain — underline attributes need a
    /// UI framework scope this Foundation-only module doesn't import.)
    private static let inlineTagRegex = try! NSRegularExpression(
        pattern: #"</?(b|strong|i|em)\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    private static let anyTagRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    private static func imageSource(in tag: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"src\s*=\s*["']([^"']+)["']"#)
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Inline text

    /// Builds an `AttributedString` from an HTML fragment: `<b>/<strong>` and
    /// `<i>/<em>` become presentation-intent runs, `<u>` underlines, all other
    /// tags are stripped, and basic entities are decoded. Returns nil when the
    /// fragment reduces to whitespace.
    private static func parseInlineText(_ fragment: String) -> AttributedString? {
        var result = AttributedString()
        var boldDepth = 0
        var italicDepth = 0

        let ns = fragment as NSString
        var cursor = 0

        func appendRun(_ raw: String) {
            let text = decodeEntities(strippingTags(raw))
            guard !text.isEmpty else { return }
            var run = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if boldDepth > 0 { intent.insert(.stronglyEmphasized) }
            if italicDepth > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            result += run
        }

        for match in inlineTagRegex.matches(in: fragment, range: NSRange(location: 0, length: ns.length)) {
            appendRun(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length

            let tag = ns.substring(with: match.range).lowercased()
            let closing = tag.hasPrefix("</")
            let delta = closing ? -1 : 1
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            switch name {
            case "b", "strong": boldDepth = max(0, boldDepth + delta)
            case "i", "em": italicDepth = max(0, italicDepth + delta)
            default: break
            }
        }
        appendRun(ns.substring(from: cursor))

        let plain = String(result.characters)
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Trim leading/trailing whitespace off the attributed result.
        if let start = plain.range(of: trimmed) {
            let lower = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: start.lowerBound))
            let upper = result.index(lower, offsetByCharacters: trimmed.count)
            return AttributedString(result[lower..<upper])
        }
        return result
    }

    private static func strippingTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return anyTagRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}

private extension NSRegularExpression {
    /// Replaces every match with `transform(firstCaptureGroup)`.
    func replacing(in string: String, transform: (String) -> String) -> String {
        let ns = string as NSString
        var result = ""
        var cursor = 0
        for match in matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(ns.substring(with: match.range(at: 1)))
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
