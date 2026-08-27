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
    var keyEquivalent: KeyEquivalent {
        key.first.map { KeyEquivalent($0) } ?? KeyEquivalent(Character(" "))
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
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
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
/// re-applied on every body evaluation, and a freshly-allocated struct of
/// closures registers as a new value each time — invalidating the scene,
/// which re-runs the body, which writes a new value again: a same-frame
/// update loop ("FocusedValue update tried to update multiple times per
/// frame") that saturates the main thread and delays every card reveal on
/// macOS. The closures are rebound once per screen appearance; identity
/// equality then makes repeat writes no-ops.
final class ReviewActions: @unchecked Sendable {
    var undo: @MainActor () -> Void = {}
    var editNote: @MainActor () -> Void = {}
    var lookup: @MainActor () -> Void = {}
    var replayAudio: @MainActor () -> Void = {}
}

struct ReviewActionsKey: FocusedValueKey {
    typealias Value = ReviewActions
}

extension FocusedValues {
    var reviewActions: ReviewActions? {
        get { self[ReviewActionsKey.self] }
        set { self[ReviewActionsKey.self] = newValue }
    }
}
