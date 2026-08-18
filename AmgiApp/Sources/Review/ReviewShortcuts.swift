import SwiftUI
import Sharing

/// A review action that can be driven from the keyboard (and rebound in
/// Settings → Shortcuts). The menu-bar "Card" menu and the review window both
/// read the same persisted binding.
enum ReviewShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case undo
    case editNote
    case lookup
    case replayAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .undo: "Undo"
        case .editNote: "Edit Note"
        case .lookup: "Look Up"
        case .replayAudio: "Replay Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .undo: "arrow.uturn.backward"
        case .editNote: "pencil"
        case .lookup: "character.book.closed"
        case .replayAudio: "play.circle"
        }
    }

    var defaultShortcut: ReviewShortcut {
        switch self {
        case .undo: ReviewShortcut(key: "z", modifiers: .command)
        case .editNote: ReviewShortcut(key: "e", modifiers: .command)
        case .lookup: ReviewShortcut(key: "l", modifiers: .command)
        case .replayAudio: ReviewShortcut(key: "r", modifiers: .command)
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
        s += key.isEmpty ? "—" : key.uppercased()
        return s
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
struct ReviewActions {
    var undo: @MainActor () -> Void
    var editNote: @MainActor () -> Void
    var lookup: @MainActor () -> Void
    var replayAudio: @MainActor () -> Void
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
