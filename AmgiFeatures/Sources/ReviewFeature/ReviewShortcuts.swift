import SwiftUI
import Sharing
import AnkiKit

/// A review action that can be driven from the keyboard (and rebound in
/// Settings → Shortcuts). The menu-bar "Card" menu and the review window both
/// read the same persisted binding.
enum ReviewShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case undo
    case editNote
    case lookup
    case replayAudio
    case revealAnswer
    case rateAgain
    case rateHard
    case rateGood
    case rateEasy
    case repeatLastRating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .undo: "Undo"
        case .editNote: "Edit Note"
        case .lookup: "Look Up"
        case .replayAudio: "Replay Audio"
        case .revealAnswer: "Reveal Answer"
        case .rateAgain: "Rate: Again"
        case .rateHard: "Rate: Hard"
        case .rateGood: "Rate: Good"
        case .rateEasy: "Rate: Easy"
        case .repeatLastRating: "Repeat Last Rating"
        }
    }

    var systemImage: String {
        switch self {
        case .undo: "arrow.uturn.backward"
        case .editNote: "pencil"
        case .lookup: "character.book.closed"
        case .replayAudio: "play.circle"
        case .revealAnswer: "eye"
        case .rateAgain: "xmark.circle"
        case .rateHard: "minus.circle"
        case .rateGood: "checkmark.circle"
        case .rateEasy: "plus.circle"
        case .repeatLastRating: "arrow.clockwise.circle"
        }
    }

    var defaultShortcut: ReviewShortcut {
        switch self {
        case .undo: ReviewShortcut(key: "z", modifiers: .command)
        case .editNote: ReviewShortcut(key: "e", modifiers: .command)
        case .lookup: ReviewShortcut(key: "l", modifiers: .command)
        case .replayAudio: ReviewShortcut(key: "r", modifiers: .command)
        case .revealAnswer: ReviewShortcut(key: " ", modifiers: [])
        case .rateAgain: ReviewShortcut(key: "1", modifiers: [])
        case .rateHard: ReviewShortcut(key: "2", modifiers: [])
        case .rateGood: ReviewShortcut(key: "3", modifiers: [])
        case .rateEasy: ReviewShortcut(key: "4", modifiers: [])
        // Only active while the answer is showing, so it never conflicts
        // with revealAnswer's default Space.
        case .repeatLastRating: ReviewShortcut(key: " ", modifiers: [])
        }
    }

    /// The rating action for a given rating (total over all ratings).
    static func ratingAction(for rating: Rating) -> ReviewShortcutAction {
        switch rating {
        case .again: .rateAgain
        case .hard: .rateHard
        case .good: .rateGood
        case .easy: .rateEasy
        }
    }
}

/// A persisted key binding — a key character plus modifier flags, encoded as
/// `EventModifiers.rawValue`. Stored as one Codable value under a single
/// appStorage key (a dictionary of action → shortcut).
struct ReviewShortcut: Equatable, Codable, Hashable, Sendable {
    var key: String
    var modifiersRaw: Int

    init(key: String, modifiers: EventModifiers) {
        self.key = key
        self.modifiersRaw = modifiers.rawValue
    }

    var modifiers: EventModifiers { EventModifiers(rawValue: modifiersRaw) }

    /// The key equivalent for `.keyboardShortcut`; falls back to a space so an
    /// empty (never-persisted) key can't crash `KeyEquivalent`.
    ///
    /// Arrow keys recorded via `.onKeyPress` are stored as NSEvent function
    /// characters (`U+F700`…`U+F703`). Mapping those to SwiftUI's
    /// `.upArrow` / etc. is required — `KeyEquivalent(Character("\u{F700}"))`
    /// does not match iPad hardware arrow events, which is why rebound
    /// rating shortcuts appeared dead.
    var keyEquivalent: KeyEquivalent {
        if let arrow = Self.arrowKeyEquivalent(for: key) { return arrow }
        if key == " " { return .space }
        return key.first.map { KeyEquivalent($0) } ?? .space
    }

    /// True when `press` is this binding. Compares only the modifier flags
    /// that users can record (⌘⌥⇧⌃), so Caps Lock / numeric-pad extras
    /// don't miss a match. Arrow / space aliases cover Settings recording
    /// (`press.key.character`) and SwiftUI's named key equivalents.
    func matches(_ press: KeyPress) -> Bool {
        let recorded = modifiers.intersection(Self.bindableModifiers)
        let pressed = press.modifiers.intersection(Self.bindableModifiers)
        guard recorded == pressed else { return false }
        return Self.keysMatch(press.key, stored: key)
    }

    private static let bindableModifiers: EventModifiers = [.command, .shift, .option, .control]

    static func keysMatch(_ key: KeyEquivalent, stored: String) -> Bool {
        if stored == String(key.character) { return true }
        if key == .space, stored == " " || stored.isEmpty { return true }
        if let arrow = arrowKeyEquivalent(for: stored), key == arrow { return true }
        if let storedFirst = stored.lowercased().first,
           String(key.character).lowercased().first == storedFirst {
            return true
        }
        return false
    }

    static func arrowKeyEquivalent(for stored: String) -> KeyEquivalent? {
        switch stored {
        case "\u{F700}", "↑": return .upArrow
        case "\u{F701}", "↓": return .downArrow
        case "\u{F702}", "←": return .leftArrow
        case "\u{F703}", "→": return .rightArrow
        default: return nil
        }
    }

    /// Human-readable form for tooltips and the settings row, e.g. "⌘Z".
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += Self.keyDisplay(key)
        return s
    }

    /// Glyphs for non-character keys (space, arrow keys) so rebound
    /// bindings like option+arrows read properly in Settings and tooltips.
    private static func keyDisplay(_ key: String) -> String {
        switch key {
        case " ": return "Space"
        case "\u{F700}", "↑": return "↑"
        case "\u{F701}", "↓": return "↓"
        case "\u{F702}", "←": return "←"
        case "\u{F703}", "→": return "→"
        default: return key.isEmpty ? "—" : key.uppercased()
        }
    }
}

extension SharedReaderKey where Self == AppStorageKey<[String: ReviewShortcut]>.Default {
    static var reviewShortcuts: Self {
        Self[.appStorage("reviewShortcuts"), default: [:]]
    }
}

/// Focused-value payload injected by the review window so the app's "Card"
/// menu can drive the focused review session. Empty outside review, which
/// disables the menu items.
///
/// A CLASS with stable identity, deliberately: `.focusedSceneValue` is
/// re-applied on every body evaluation, and a freshly-allocated value
/// registers as a change — invalidating the scene, which re-runs the body,
/// which writes a new value again: a same-frame update loop.
///
/// Xcode 26 removed `@FocusedSceneValue` / `FocusedSceneValues`. Publish
/// this `@Observable` object with `.focusedSceneValue(reviewActions)` and
/// read it from commands with `@FocusedValue(ReviewActions.self)` — that
/// pair is scene-scoped, so Edit → Undo / ⌘Z keep working when the card
/// web view would otherwise steal view-level focus. Closures are rebound
/// once per screen appearance.
@MainActor
@Observable
final class ReviewActions {
    var undo: @MainActor () -> Void = {}
    var editNote: @MainActor () -> Void = {}
    var lookup: @MainActor () -> Void = {}
    var replayAudio: @MainActor () -> Void = {}
}

/// Dispatches a hardware key press to a review action. Used instead of
/// (or in addition to) `.keyboardShortcut` so iPad arrow keys aren't
/// stolen by the focus engine, and so Space key-repeat can't flash
/// through the deck.
enum ReviewKeyDispatch {
    /// `.handled` for a bound action, including consumed key-repeat of
    /// reveal/rate/space so the event doesn't fall through. Undo still
    /// fires on repeat (hold ⌘Z to walk back).
    ///
    /// Space is still two distinct taps: front → reveal, back → repeat
    /// last rating (Again on new cards). Only `phase == .repeat` is
    /// ignored, so holding Space cannot reveal-and-answer in one press.
    static func handle(
        _ press: KeyPress,
        bindings: [String: ReviewShortcut],
        isTypedAnswerEditing: Bool,
        showAnswer: Bool,
        perform: (ReviewShortcutAction) -> Void
    ) -> KeyPress.Result {
        if isTypedAnswerEditing { return .ignored }
        let matches = ReviewShortcutAction.allCases.filter { action in
            let shortcut = bindings[action.rawValue] ?? action.defaultShortcut
            return shortcut.matches(press)
        }
        guard let action = matches.first(where: { $0.isAvailable(showAnswer: showAnswer) })
                ?? matches.first
        else {
            return .ignored
        }
        if !action.isAvailable(showAnswer: showAnswer) { return .ignored }
        if action.ignoresKeyRepeat, press.phase == .repeat {
            return .handled
        }
        if press.phase == .up { return .ignored }
        perform(action)
        return .handled
    }

    static func matchingAction(
        _ press: KeyPress,
        bindings: [String: ReviewShortcut]
    ) -> ReviewShortcutAction? {
        ReviewShortcutAction.allCases.first { action in
            let shortcut = bindings[action.rawValue] ?? action.defaultShortcut
            return shortcut.matches(press)
        }
    }
}

private extension ReviewShortcutAction {
    /// Reveal / rate / repeat-last-rating must not fire on key-repeat:
    /// holding Space would otherwise reveal and immediately answer every
    /// card. Undo (and the chrome actions) stay repeatable.
    var ignoresKeyRepeat: Bool {
        switch self {
        case .revealAnswer, .repeatLastRating,
             .rateAgain, .rateHard, .rateGood, .rateEasy:
            true
        default:
            false
        }
    }

    func isAvailable(showAnswer: Bool) -> Bool {
        switch self {
        case .revealAnswer: !showAnswer
        case .repeatLastRating, .rateAgain, .rateHard, .rateGood, .rateEasy:
            showAnswer
        default:
            true
        }
    }
}
