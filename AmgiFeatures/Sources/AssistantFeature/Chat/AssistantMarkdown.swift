import AmgiTheme
import AmgiUI
import SwiftUI

/// Renders a reply's Markdown by block: paragraphs, headings, bullet and
/// numbered lists, quotes and code. `Text(markdown:)` only does inline
/// styles, which turned a cloud model's lists into one run-on paragraph.
/// Tolerates a half-streamed reply: an open code fence renders as code.
struct AssistantMarkdown: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.md) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(Self.inline(text))
                .amgiFont(level <= 2 ? .cardTitle : .bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
                .padding(.top, AmgiSpacing.xs)
        case .list(let items):
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: AmgiSpacing.sm) {
                        Text(item.marker)
                            .amgiFont(.body)
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(item.text))
                            .amgiFont(.body)
                            .foregroundStyle(palette.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * AmgiSpacing.lg)
                }
            }
        case .quote(let text):
            Text(Self.inline(text))
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .padding(.leading, AmgiSpacing.md)
                .overlay(alignment: .leading) {
                    Capsule().fill(palette.separator).frame(width: 3)
                }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .padding(AmgiSpacing.md)
            }
            .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        case .rule:
            Rectangle().fill(palette.separator).frame(height: 1)
        }
    }

    // MARK: Parsing

    struct ListItem: Equatable {
        let marker: String
        let text: String
        let indent: Int
    }

    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case list([ListItem])
        case quote(String)
        case code(String)
        case rule
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    nonisolated static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " ", line.distance(from: line.startIndex, to: hashes) <= 6 {
                flush()
                blocks.append(.heading(line.distance(from: line.startIndex, to: hashes), String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if let item = listItem(line, indent: min(indent, 3)) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                list.append(item)
                continue
            }
            if !list.isEmpty, raw.hasPrefix("  "), let last = list.popLast() {
                // A wrapped list item.
                list.append(ListItem(marker: last.marker, text: last.text + " " + line, indent: last.indent))
                continue
            }
            if !list.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private nonisolated static func listItem(_ line: String, indent: Int) -> ListItem? {
        for bullet in ["- ", "* ", "• ", "+ "] where line.hasPrefix(bullet) {
            return ListItem(marker: "•", text: String(line.dropFirst(bullet.count)), indent: indent)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ListItem(marker: "\(digits).", text: String(rest.dropFirst(2)), indent: indent)
    }
}
