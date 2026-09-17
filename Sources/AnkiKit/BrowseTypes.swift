import Foundation

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

/// Result of the aux exact-duplicate scan (`anki-bridge-rs` service 200).
/// Wire format is JSON — keep types Codable.
public struct FindDuplicatesResult: Sendable, Equatable, Codable {
    public struct Group: Sendable, Equatable, Codable {
        /// The duplicated field text (HTML stripped).
        public let value: String
        public let noteIds: [Int64]

        public init(value: String, noteIds: [Int64]) {
            self.value = value
            self.noteIds = noteIds
        }
    }

    public let groups: [Group]
    /// Notes examined during the scan.
    public let notesScanned: Int

    public init(groups: [Group], notesScanned: Int) {
        self.groups = groups
        self.notesScanned = notesScanned
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

/// Hierarchical tag tree node (desktop sidebar parity). Paths are
/// `::`-joined; `collapsed` persists engine-side via SetTagCollapsed.
public struct TagTreeNodeData: Sendable, Equatable {
    public let name: String
    public let fullPath: String
    public let level: UInt32
    public let collapsed: Bool
    public let children: [TagTreeNodeData]

    public init(name: String, fullPath: String, level: UInt32, collapsed: Bool, children: [TagTreeNodeData]) {
        self.name = name
        self.fullPath = fullPath
        self.level = level
        self.collapsed = collapsed
        self.children = children
    }
}

/// Field/template mapping preview for note-type conversion
/// (desktop Change Notetype dialog).
public struct ChangeNotetypeInfo: Sendable, Equatable {
    public let oldFieldNames: [String]
    public let oldTemplateNames: [String]
    public let newFieldNames: [String]
    public let newTemplateNames: [String]
    public let oldNotetypeName: String
    public let currentSchema: Int64

    public init(
        oldFieldNames: [String], oldTemplateNames: [String],
        newFieldNames: [String], newTemplateNames: [String],
        oldNotetypeName: String, currentSchema: Int64
    ) {
        self.oldFieldNames = oldFieldNames
        self.oldTemplateNames = oldTemplateNames
        self.newFieldNames = newFieldNames
        self.newTemplateNames = newTemplateNames
        self.oldNotetypeName = oldNotetypeName
        self.currentSchema = currentSchema
    }
}

/// One review-log row for the Card Info history table.
public struct RevlogEntry: Sendable, Equatable {
    public let id: Int64
    public let rating: Int32
    public let intervalSecs: Int64
    public let easeFactor: Int32
    public let takenSecs: Int64
    public let reviewKind: Int32

    public init(id: Int64, rating: Int32, intervalSecs: Int64, easeFactor: Int32, takenSecs: Int64, reviewKind: Int32) {
        self.id = id
        self.rating = rating
        self.intervalSecs = intervalSecs
        self.easeFactor = easeFactor
        self.takenSecs = takenSecs
        self.reviewKind = reviewKind
    }
}

/// Full card-stats payload for the Info pane: scheduling facts plus
/// newest-first review history with FSRS memory state where available.
public struct CardStatsInfo: Sendable, Equatable {
    public let revlog: [RevlogEntry]
    public let stability: Float?
    public let difficulty: Float?
    public let retrievabilityPct: Float?

    public init(revlog: [RevlogEntry], stability: Float?, difficulty: Float?, retrievabilityPct: Float?) {
        self.revlog = revlog
        self.stability = stability
        self.difficulty = difficulty
        self.retrievabilityPct = retrievabilityPct
    }
}

/// Persisted Browse view preferences (per mode where noted). Stored in
/// UserDefaults, profile-scoped where the key includes the profile id.
public struct BrowseViewPrefs: Sendable, Equatable, Codable {
    public var cardsColumns: [String]
    public var notesColumns: [String]
    public var cardsSortColumn: String
    public var cardsSortReverse: Bool
    public var notesSortColumn: String
    public var notesSortReverse: Bool
    public var previewBackSideOnly: Bool

    public init(
        cardsColumns: [String] = ["question", "deck", "cardDue"],
        notesColumns: [String] = ["noteFld", "note", "noteTags"],
        cardsSortColumn: String = "cardMod",
        cardsSortReverse: Bool = true,
        notesSortColumn: String = "noteMod",
        notesSortReverse: Bool = true,
        previewBackSideOnly: Bool = false
    ) {
        self.cardsColumns = cardsColumns
        self.notesColumns = notesColumns
        self.cardsSortColumn = cardsSortColumn
        self.cardsSortReverse = cardsSortReverse
        self.notesSortColumn = notesSortColumn
        self.notesSortReverse = notesSortReverse
        self.previewBackSideOnly = previewBackSideOnly
    }
}
