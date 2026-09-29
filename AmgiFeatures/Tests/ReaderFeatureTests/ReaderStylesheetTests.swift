import Foundation
import Testing
@testable import ReaderFeature

/// Assertions about the reader stylesheet and injected script.
///
/// These are file-level checks on hand-written CSS/JS that no Swift compiler
/// sees, covering the two defects that were shipped once already: a dashed
/// underline on every word, and vertical page insets that silently did nothing.
@Suite("Reader stylesheet")
struct ReaderReaderStylesheetTests {
    static let cssPath =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReaderFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AmgiFeatures
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("AmgiApp/Resources/EPUBReader/EPUBReaderStyles.css")

    private func css() throws -> String {
        try String(contentsOf: Self.cssPath, encoding: .utf8)
    }

    /// Body text of every rule with exactly this selector.
    ///
    /// Hand-rolled rather than using a CSS parser so the tests add no
    /// dependency, but it does the two things a naive `split` gets wrong:
    /// comments are stripped first (otherwise a comment ahead of a rule is
    /// mistaken for part of its selector), and *all* matching rules are
    /// returned rather than just the last (`.amgi-tok` and
    /// `.amgi-tok[data-amgi-pressed="1"]` are different rules).
    private func ruleBodies(selector: String, in source: String) -> [String] {
        let withoutComments = stripComments(source)
        var bodies: [String] = []
        var cursor = withoutComments.startIndex
        var selectorStart = withoutComments.startIndex
        while let open = withoutComments[ cursor... ].firstIndex(of: "{") {
            let header = withoutComments[selectorStart..<open]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let close = withoutContents(
                withoutComments,
                from: withoutComments.index(after: open),
                until: "}"
            ) else { break }
            if header == selector {
                bodies.append(
                    String(withoutComments[
                        withoutComments.index(after: open)..<close
                    ])
                )
            }
            cursor = withoutComments.index(after: close)
            selectorStart = cursor
        }
        return bodies
    }

    private func stripComments(_ source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound..<rest.endIndex) else {
                return out
            }
            // Keep a space so `a/*x*/b` does not become `ab`.
            out += " "
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Index of `needle` at or after `start`, ignoring braces so a `{` inside a
    /// declaration does not end the rule early.
    private func withoutContents(
        _ source: String,
        from start: String.Index,
        until needle: String
    ) -> String.Index? {
        var depth = 1
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // MARK: - Token affordance

    @Test("tokens are not decorated at rest")
    func tokensHaveNoPersistentDecoration() throws {
        // The shipped bug: `.amgi-tok { text-decoration: underline dashed … }`
        // drew a dashed underline under every word in the book, which is
        // unreadable and reads as broken rendering.
        let blocks = ruleBodies(selector: ".amgi-tok", in: try css())
        #expect(!blocks.isEmpty, "no `.amgi-tok` rule found")
        for block in blocks {
            #expect(
                !block.contains("text-decoration: underline"),
                "tokens must not be underlined: \(block)"
            )
            #expect(
                !block.contains("border-bottom"),
                "tokens must not draw a border at rest: \(block)"
            )
        }
    }

    @Test("the token rule is layout-invisible")
    func tokensDoNotShiftLayout() throws {
        // Tokenisation wraps every word in a span. If the span gained padding,
        // a border, a margin, or a different font, the text would reflow on
        // load and every saved reading position would be wrong.
        //
        // Zero-valued resets are allowed and expected — they are what stops a
        // book's own `span { … }` rule from leaking in. What is forbidden is a
        // *non-zero* value, which is the actual failure mode.
        let blocks = ruleBodies(selector: ".amgi-tok", in: try css())
        #expect(!blocks.isEmpty, "no `.amgi-tok` rule found")
        let layoutAffecting = ["padding", "margin", "border-width", "font-size", "letter-spacing"]
        for block in blocks {
            for declaration in block.split(separator: ";") {
                let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let property = trimmed[trimmed.startIndex..<colon]
                    .trimmingCharacters(in: .whitespaces)
                // `!important` follows the value, not the property.
                let value = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "!important", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard layoutAffecting.contains(property) else { continue }
                // A zero reset, or the `inherit`/`normal` keywords, is fine.
                let isNeutral = value == "0" || value == "0px" || value == "none"
                    || value.hasPrefix("inherit") || value == "normal"
                #expect(
                    isNeutral,
                    "`.amgi-tok` must be layout-invisible, but sets \(property): \(value)"
                )
            }
        }
    }

    @Test("there is a press tint for feedback while a finger is down")
    func pressTintExists() throws {
        let source = try css()
        #expect(source.contains("--reader-press"))
        #expect(source.contains("data-amgi-pressed"))
    }

    // MARK: - Vertical insets

    @Test("the vertical inset is applied to html, not body")
    func verticalInsetIsOnHTML() throws {
        // This is the bug behind "the last line sits behind the page counter".
        // <body> is a *fragmented* box in a multi-column flow, so its
        // top/bottom padding applies only at the very start and end of the
        // whole flow. <html> is the scroll container, not a fragment, so its
        // padding insets every column.
        let blocks = ruleBodies(selector: "body", in: try css())
        #expect(!blocks.isEmpty, "no `body` rule found")
        for block in blocks {
            #expect(
                !block.contains("padding-top"),
                "body padding-top only insets the first page: \(block)"
            )
            #expect(
                !block.contains("padding-bottom"),
                "body padding-bottom only insets the last page: \(block)"
            )
        }
    }

    @Test("html carries the vertical inset and subtracts it from the column height")
    func htmlCarriesVerticalInset() throws {
        let source = try css()
        #expect(source.contains("--reader-inset-top"))
        #expect(source.contains("--reader-inset-bottom"))
        // border-box is what makes the padding reduce the column height rather
        // than extend the content beyond the viewport.
        #expect(source.contains("box-sizing: border-box"))
        let blocks = ruleBodies(selector: "html", in: source)
        #expect(!blocks.isEmpty, "no `html` rule found")
        #expect(
            blocks.contains { $0.contains("--reader-inset-top") },
            "no html rule applies the top inset"
        )
        #expect(
            blocks.contains { $0.contains("--reader-inset-bottom") },
            "no html rule applies the bottom inset"
        )
    }

    @Test("the page gutter stays horizontal on body")
    func pageGutterIsHorizontal() throws {
        // The spec *does* apply left/right padding to every fragment, so the
        // horizontal page margin belongs on body.
        let blocks = ruleBodies(selector: "body", in: try css())
        #expect(
            blocks.contains { $0.contains("--reader-page-margin") },
            "the horizontal page gutter must stay on body"
        )
    }

    // MARK: - Book font

    @Test("the font override is gated on the user having chosen a family")
    func fontOverrideIsGated() throws {
        // A book that embeds a serif face must keep it, as Apple Books does.
        // The override is `!important`, so an ungated rule silently replaces
        // the book's entire typography.
        let source = try css()
        #expect(source.contains("--reader-honour-book-font"))
        #expect(source.contains("data-amgi-honour-book-font"))
        #expect(
            !source.contains("body, body * {\n  font-family"),
            "an ungated `body, body *` font-family rule defeats the gate"
        )
    }

    @Test("the stylesheet parses as CSS with balanced braces")
    func bracesAreBalanced() throws {
        let source = try css()
        let open = source.filter { $0 == "{" }.count
        let close = source.filter { $0 == "}" }.count
        #expect(open == close, "unbalanced braces: \(open) open, \(close) close")
    }
}

@Suite("Reader tap behaviour")
struct ReaderTapBehaviourTests {
    static let jsPath =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReaderFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AmgiFeatures
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("AmgiApp/Resources/EPUBReader/EPUBReaderInjection.js")

    private func js() throws -> String {
        try String(contentsOf: Self.jsPath, encoding: .utf8)
    }

    @Test("no single tap posts a lookup")
    func tapDoesNotTriggerLookup() throws {
        // The behaviour being removed: a click on any token opened the
        // dictionary. A reader should be able to touch a word while reading
        // without a sheet appearing.
        let source = try js()
        #expect(
            !source.contains("messageHandlers.wordTap"),
            "wordTap must not be posted any more"
        )
    }

    @Test("a tap only produces a press tint")
    func tapOnlyTints() throws {
        let source = try js()
        // The press feedback is a data attribute, not a message.
        #expect(source.contains("PRESS_ATTR"))
        #expect(source.contains("data-amgi-pressed"))
    }

    @Test("long press selection is reported so the menu can be extended")
    func selectionIsReported() throws {
        let source = try js()
        #expect(source.contains("messageHandlers.wordSelection"))
        #expect(source.contains("selectionchange"))
        // The payload must carry the selected text and an anchor, or the
        // menu's actions have nothing to act on.
        #expect(source.contains("selection:"))
        #expect(source.contains("anchor:"))
    }

    @Test("the tap handler is defined exactly once")
    func tapHandlerIsNotDuplicated() throws {
        // Function declarations hoist, so a second `installTapHandler` silently
        // replaces the first. That is how a dead code path shipped once: the
        // new handler existed and was simply never called.
        let source = try js()
        let count = source.components(
            separatedBy: "function installTapHandler("
        ).count - 1
        #expect(count == 1, "found \(count) installTapHandler definitions")
    }

    @Test("the macOS quote-to-anchor helper exists")
    func quoteAnchorHelperExists() throws {
        // macOS learns the selection as a plain string, after the Range is
        // gone, so it needs a way to re-anchor from the quote alone.
        let source = try js()
        #expect(source.contains("__amgiAnchorForQuote"))
    }
}
