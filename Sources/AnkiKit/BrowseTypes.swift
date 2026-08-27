public import Foundation

// Domain mirrors for the browser-table engine surface (`search.proto`
// BrowserRow/BrowserColumns + duplicate detection). Protobuf shapes stay
// inside AnkiProtoBridge; UI-facing modules see only these.

/// Elide behaviour recommended by the engine for a cell's text.
public enum BrowserCellElide: Sendable, Equatable {
    case left, right, middle, none
}

/// Row-level semantic color: card state or flag, straight from the
/// engine so theming decisions stay in one place (AmgiUI maps these to
/// palette slots; consumers never parse strings).
public enum BrowserRowColor: Sendable, Equatable {
    case normal
    case marked
    case suspended
    case buried
    case flagRed, flagOrange, flagGreen, flagBlue, flagPink, flagTurquoise, flagPurple
}

public struct BrowserCell: Sendable, Equatable {
    public let text: String
    public let isRTL: Bool
    public let elide: BrowserCellElide

    public init(text: String, isRTL: Bool = false, elide: BrowserCellElide = .right) {
        self.text = text
        self.isRTL = isRTL
        self.elide = elide
    }
}

/// One rendered table row from `BrowserRowForId`. Cell order matches
/// the active column set pushed via `SetActiveBrowserColumns`.
public struct BrowserRowData: Sendable, Equatable {
    public let cells: [BrowserCell]
    public let color: BrowserRowColor
    public let fontName: String?
    /// Engine-provided pixel size; nil means "use system default".
    public let fontSize: UInt32?

    public init(cells: [BrowserCell], color: BrowserRowColor, fontName: String?, fontSize: UInt32?) {
        self.cells = cells
        self.color = color
        self.fontName = fontName
        self.fontSize = fontSize
    }
}

public enum BrowserColumnSorting: String, Sendable, Equatable {
    case none
    case ascending
    case descending
}

public enum BrowserColumnAlignment: String, Sendable, Equatable {
    case center
    case start
}

/// One entry of `AllBrowserColumns`: metadata about a sortable column.
public struct BrowserColumnSpec: Sendable, Equatable {
    /// Stable key used both for sorting requests and column activation.
    public let key: String
    public let cardsLabel: String
    public let notesLabel: String
    public let cardsSorting: BrowserColumnSorting
    public let notesSorting: BrowserColumnSorting
    public let alignment: BrowserColumnAlignment
    public let usesCellFont: Bool

    public init(key: String, cardsLabel: String, notesLabel: String,
                cardsSorting: BrowserColumnSorting, notesSorting: BrowserColumnSorting,
                alignment: BrowserColumnAlignment, usesCellFont: Bool) {
        self.key = key
        self.cardsLabel = cardsLabel
        self.notesLabel = notesLabel
        self.cardsSorting = cardsSorting
        self.notesSorting = notesSorting
        self.alignment = alignment
        self.usesCellFont = usesCellFont
    }
}

/// Queue-changing batch op for Browse selection actions.
public enum SuspendBuryMode: Sendable, Equatable {
    /// Toggle into/out of the suspended queue state.
    case suspend
    /// Re-hide cards auto-buried by sibling avoidance.
    case buryScheduled
    /// Manual bury — hides until tomorrow.
    case buryUser
}

/// What undo/redo would act on, for toolbar labels ("Undo Delete Notes").
public struct UndoStatusInfo: Sendable, Equatable {
    public let canUndo: Bool
    public let undoText: String
    public let canRedo: Bool
    public let redoText: String

    public init(canUndo: Bool, undoText: String, canRedo: Bool, redoText: String) {
        self.canUndo = canUndo
        self.undoText = undoText
        self.canRedo = canRedo
        self.redoText = redoText
    }
}

/// One value-group of duplicate notes for a field.
public struct DuplicateGroup: Sendable, Equatable {
    /// The duplicated field text.
    public let value: String
    public let noteIDs: [NoteID]

    public init(value: String, noteIDs: [NoteID]) {
        self.value = value
        self.noteIDs = noteIDs
    }
}
