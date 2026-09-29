import AmgiReader
import Foundation

/// The menu a long press produces, matching what the platform does natively
/// and adding the actions this reader is for.
///
/// Why a reader-built menu rather than leaving WebKit's callout alone:
/// WebKit's callout has Copy / Look Up / Share / Translate, but nothing that
/// knows about Anki. Replacing it wholesale would throw away the platform
/// behaviour (magnetic word snapping, drag handles, Translate) and
/// reimplement it worse, so the standard items are reproduced alongside the
/// Anki ones and the whole set is presented together.
///
/// Platform-neutral on purpose: the shape of the menu is identical on iOS and
/// macOS, so it is defined once here and only the *presentation* differs
/// (`ReaderSelectionMenuController` on iOS, `NSMenu` in the macOS host).
/// Tests assert the shape here, without a live menu.
/// Deliberately not actor-isolated: it is a plain value that crosses from the
/// script bridge into whichever platform presents the menu, and keeping it
/// nonisolated means its shape is testable without a main-actor context.
struct ReaderSelectionPayload: Sendable {
    /// The full selected range — what Copy and a highlight should use.
    let text: String
    /// The word under the selection start — what a dictionary should ask
    /// about. A five-word selection still looks up one word, as Apple does.
    let token: String
    /// The sentence around it, for the note draft.
    let sentence: String
    let anchor: ReaderSourceAnchor?

    init(text: String, token: String, sentence: String, anchor: ReaderSourceAnchor?) {
        self.text = text
        self.token = token
        self.sentence = sentence
        self.anchor = anchor
    }
}

/// Actions the reader offers on a selection.
///
/// `String`-backed because the macOS menu carries the action across as an
/// `NSMenuItem.representedObject`, and a shared raw value keeps the two
/// platforms from drifting.
enum ReaderSelectionAction: String, CaseIterable, Sendable {
    case lookUp
    case highlight
    case bookmark
    case addNote
    case copy
}

@MainActor
protocol ReaderSelectionMenuPresenting: AnyObject {
    func readerSelectionMenu(_ action: ReaderSelectionAction, payload: ReaderSelectionPayload)
}

enum ReaderSelectionMenu {
    /// Titles in presentation order. Asserted by tests because a menu that
    /// silently loses "Look Up" is indistinguishable, to a user, from a
    /// broken long press.
    static let actionOrder: [ReaderSelectionAction] = [
        .lookUp, .addNote, .highlight, .bookmark, .copy,
    ]

    static func title(for action: ReaderSelectionAction) -> String {
        switch action {
        case .lookUp: "Look Up"
        case .highlight: "Highlight"
        case .bookmark: "Bookmark"
        case .addNote: "Add Note"
        case .copy: "Copy"
        }
    }

    static func systemImage(for action: ReaderSelectionAction) -> String {
        switch action {
        case .lookUp: "text.book.closed"
        case .highlight: "highlighter"
        case .bookmark: "bookmark"
        case .addNote: "text.badge.plus"
        case .copy: "doc.on.doc"
        }
    }

    /// Whether an action is meaningful for a selection.
    ///
    /// Look Up, Add Note and Copy need text to act on. Highlight and Bookmark
    /// additionally need an anchor, because a mark with no way back to its
    /// position is a dead end — better to omit the action than to store one
    /// that can only ever be found by searching.
    static func isAvailable(
        _ action: ReaderSelectionAction,
        for payload: ReaderSelectionPayload
    ) -> Bool {
        let hasText = !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch action {
        case .lookUp, .addNote, .copy:
            return hasText
        case .highlight, .bookmark:
            return hasText && payload.anchor != nil
        }
    }

    /// Actions to show for a selection, in order.
    static func availableActions(
        for payload: ReaderSelectionPayload
    ) -> [ReaderSelectionAction] {
        actionOrder.filter { isAvailable($0, for: payload) }
    }
}
