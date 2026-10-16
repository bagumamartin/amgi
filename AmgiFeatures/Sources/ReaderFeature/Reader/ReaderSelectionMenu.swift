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
/// (merged into the system's own menu by `ReaderSystemSelectionMenu`).
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

/// Actions the reader offers on a selection that do not involve a card.
///
/// `String`-backed because the macOS menu carries the action across as an
/// `NSMenuItem.representedObject`, and a shared raw value keeps the two
/// platforms from drifting.
///
/// "Add Note" used to live here and did exactly what Look Up did — opened the
/// dictionary. Card creation now has its own commands (`ReaderCardMenuCommand`)
/// that never open a sheet.
enum ReaderSelectionAction: String, CaseIterable, Sendable {
    case lookUp
    case highlight
    case bookmark
    case copy
}

/// What a card item in the selection menu does.
enum ReaderCardMenuCommand: Hashable, Sendable {
    /// Start a new draft with the selection on its front.
    case newCard
    /// Add the selection to one side of an existing draft.
    case add(draftID: UUID, side: ReaderCardDraft.Side)
}

/// The draft stack, as the menu needs to see it. Frontmost first.
struct ReaderCardMenuContext: Sendable, Equatable {
    struct Draft: Sendable, Equatable {
        let id: UUID
        let title: String
    }

    var drafts: [Draft] = []
}

/// One row of the selection menu.
indirect enum ReaderSelectionMenuEntry: Hashable, Sendable {
    case action(ReaderSelectionAction)
    case card(ReaderCardMenuCommand, title: String, systemImage: String)
    case submenu(title: String, systemImage: String, children: [ReaderSelectionMenuEntry])

    var title: String {
        switch self {
        case .action(let action): ReaderSelectionMenu.title(for: action)
        case .card(_, let title, _), .submenu(let title, _, _): title
        }
    }

    var systemImage: String {
        switch self {
        case .action(let action): ReaderSelectionMenu.systemImage(for: action)
        case .card(_, _, let image), .submenu(_, let image, _): image
        }
    }
}

enum ReaderSelectionMenu {
    /// Non-card actions in presentation order. Asserted by tests because a
    /// menu that silently loses "Look Up" is indistinguishable, to a user,
    /// from a broken long press.
    static let actionOrder: [ReaderSelectionAction] = [
        .lookUp, .highlight, .bookmark, .copy,
    ]

    static func title(for action: ReaderSelectionAction) -> String {
        switch action {
        case .lookUp: "Look Up"
        case .highlight: "Highlight"
        case .bookmark: "Bookmark"
        case .copy: "Copy"
        }
    }

    static func systemImage(for action: ReaderSelectionAction) -> String {
        switch action {
        case .lookUp: "text.book.closed"
        case .highlight: "highlighter"
        case .bookmark: "bookmark"
        case .copy: "doc.on.doc"
        }
    }

    static let makeCardImage = "rectangle.stack.badge.plus"
    static let addToBackImage = "rectangle.bottomhalf.inset.filled"
    static let addToFrontImage = "rectangle.tophalf.inset.filled"
    static let addToCardImage = "rectangle.on.rectangle"

    /// Whether an action is meaningful for a selection.
    ///
    /// Look Up and Copy need text to act on. Highlight and Bookmark
    /// additionally need an anchor, because a mark with no way back to its
    /// position is a dead end — better to omit the action than to store one
    /// that can only ever be found by searching.
    static func isAvailable(
        _ action: ReaderSelectionAction,
        for payload: ReaderSelectionPayload
    ) -> Bool {
        let hasText = hasText(payload)
        switch action {
        case .lookUp, .copy:
            return hasText
        case .highlight, .bookmark:
            return hasText && payload.anchor != nil
        }
    }

    /// Non-card actions to show for a selection, in order.
    static func availableActions(
        for payload: ReaderSelectionPayload
    ) -> [ReaderSelectionAction] {
        actionOrder.filter { isAvailable($0, for: payload) }
    }

    /// The whole menu for a selection, given the draft stack.
    ///
    /// The one decision that matters: with a draft waiting, "Add to Back"
    /// leads, because the reader is almost certainly selecting the answer the
    /// waiting card is missing. It names the card it fills, so with several
    /// waiting there is no guessing which one is in front. Without a draft,
    /// "Make Card" sits right after Look Up.
    ///
    /// Every other draft is one level down, in "Other Cards", backs first —
    /// an answer is what a waiting card is missing. The top level stays short
    /// however many drafts are open. Picking a different card to lead is also
    /// a tap on its tab in the dock, and any card takes a dragged selection.
    static func entries(
        for payload: ReaderSelectionPayload,
        context: ReaderCardMenuContext
    ) -> [ReaderSelectionMenuEntry] {
        let actions = availableActions(for: payload)
        guard hasText(payload) else { return actions.map { .action($0) } }

        var entries: [ReaderSelectionMenuEntry] = []
        let front = context.drafts.first
        let others = context.drafts.dropFirst()
        if let front {
            entries.append(.card(
                .add(draftID: front.id, side: .back),
                title: others.isEmpty ? "Add to Back" : "Add to Back of \(quoted(front.title))",
                systemImage: addToBackImage
            ))
        }
        if actions.contains(.lookUp) { entries.append(.action(.lookUp)) }
        entries.append(.card(.newCard, title: front == nil ? "Make Card" : "New Card", systemImage: makeCardImage))
        var trailing: [ReaderSelectionMenuEntry] = []
        if let front, others.isEmpty {
            // Rare enough to sit at the end, and a submenu of one is a detour.
            trailing.append(.card(.add(draftID: front.id, side: .front), title: "Add to Front", systemImage: addToFrontImage))
        } else if let front {
            var children: [ReaderSelectionMenuEntry] = others.map {
                .card(.add(draftID: $0.id, side: .back), title: "Back of \(quoted($0.title))", systemImage: addToBackImage)
            }
            children.append(.card(.add(draftID: front.id, side: .front), title: "Front of \(quoted(front.title))", systemImage: addToFrontImage))
            children += others.map {
                .card(.add(draftID: $0.id, side: .front), title: "Front of \(quoted($0.title))", systemImage: addToFrontImage)
            }
            entries.append(.submenu(title: "Other Cards", systemImage: addToCardImage, children: children))
        }
        entries.append(contentsOf: actions.filter { $0 != .lookUp }.map { .action($0) })
        return entries + trailing
    }

    /// A draft's title as a menu item shows it. The edit menu is one row on a
    /// phone, so a long front is cut harder here than in the dock.
    static let menuTitleLength = 14

    static func quoted(_ title: String) -> String {
        let trimmed = title.hasSuffix("…") ? String(title.dropLast()) : title
        let short = trimmed.count > menuTitleLength
            ? String(trimmed.prefix(menuTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
            : title
        return "“\(short)”"
    }

    private static func hasText(_ payload: ReaderSelectionPayload) -> Bool {
        !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
