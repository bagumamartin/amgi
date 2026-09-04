import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - buildSearchString

extension Request where Response == String {
    /// Validates/canonicalizes a search query the way desktop does before
    /// running it (also surfaces grammar errors as engine exceptions).
    /// Accepts raw text; `parsableText` tells the engine to reparse it.
    public static func buildSearchString(query: String) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.buildSearchString,
            encode: {
                var proto = Anki_Search_SearchNode()
                proto.parsableText = query
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_String(serializedBytes: bytes).val
            }
        )
    }

    /// Composes two parsable nodes with AND/OR — sidebar multi-select and
    /// modifier-click composition ride on this.
    public static func joinSearchNodes(existing: String, additional: String, joiner: SearchJoiner) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.joinSearchNodes,
            encode: {
                var proto = Anki_Search_JoinSearchNodesRequest()
                proto.joiner = joiner == .or ? .or : .and
                proto.existingNode.parsableText = existing
                proto.additionalNode.parsableText = additional
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_String(serializedBytes: bytes).val
            }
        )
    }

    /// Substitutes one node type for another in a composed search
    /// (e.g. clicking a different card-state while holding ⌃).
    public static func replaceSearchNode(previous: String, replacement: String) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.replaceSearchNode,
            encode: {
                var proto = Anki_Search_ReplaceSearchNodeRequest()
                proto.existingNode.parsableText = previous
                proto.replacementNode.parsableText = replacement
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_String(serializedBytes: bytes).val
            }
        )
    }
}

public enum SearchJoiner: Sendable, Equatable {
    case and
    case or
}

// MARK: - findAndReplace

extension Request where Response == Int {
    /// Bulk text substitution across the given notes. Returns the number
    /// of notes changed. Empty `fieldName` targets all fields.
    public static func findAndReplace(
        noteIds: [NoteID],
        search: String,
        replacement: String,
        isRegex: Bool,
        matchCase: Bool,
        fieldName: String?
    ) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.findAndReplace,
            encode: {
                var proto = Anki_Search_FindAndReplaceRequest()
                proto.nids = noteIds.map(\.rawValue)
                proto.search = search
                proto.replacement = replacement
                proto.regex = isRegex
                proto.matchCase = matchCase
                if let fieldName { proto.fieldName = fieldName }
                return try proto.serializedData()
            },
            decode: { bytes in
                Int(try Anki_Collection_OpChangesWithCount(serializedBytes: bytes).count)
            }
        )
    }
}

// MARK: - browser columns / rows

extension Request where Response == [BrowserColumnSpec] {
    /// Catalog of every sortable browser column with per-mode metadata.
    public static func allBrowserColumns() -> Self {
        .empty(
            serviceId: ServiceID.search,
            methodId: SearchMethod.allBrowserColumns,
            decode: { bytes in
                let proto = try Anki_Search_BrowserColumns(serializedBytes: bytes)
                return proto.columns.map {
                    BrowserColumnSpec(
                        key: $0.key,
                        cardsLabel: $0.cardsModeLabel,
                        notesLabel: $0.notesModeLabel,
                        cardsSorting: mirrorSorting($0.sortingCards),
                        notesSorting: mirrorSorting($0.sortingNotes),
                        alignment: $0.alignment == .center ? .center : .start,
                        usesCellFont: $0.usesCellFont
                    )
                }
            }
        )
    }

    private static func mirrorSorting(_ s: Anki_Search_BrowserColumns.Sorting) -> BrowserColumnSorting {
        switch s {
        case .ascending: .ascending
        case .descending: .descending
        default: .none
        }
    }
}

extension Request where Response == Void {
    /// Persists the active column keys engine-side so the same set comes
    /// back for future sessions and stays coherent with desktop.
    public static func setActiveBrowserColumns(_ keys: [String]) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.setActiveBrowserColumns,
            encode: {
                var proto = Anki_Generic_StringList()
                proto.vals = keys
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

extension Request where Response == BrowserRowData {
    /// One engine-rendered table row. Cell order follows the active
    /// column set; see `BrowserRowData`.
    public static func browserRowForId(id: Int64) -> Self {
        Self(
            serviceId: ServiceID.search,
            methodId: SearchMethod.browserRowForId,
            encode: {
                var proto = Anki_Generic_Int64()
                proto.val = id
                return try proto.serializedData()
            },
            decode: { bytes in
                let proto = try Anki_Search_BrowserRow(serializedBytes: bytes)
                let cells = proto.cells.map {
                    BrowserCell(text: $0.text, isRTL: $0.isRtl, elide: mirrorElide($0.elideMode))
                }
                let color: BrowserRowColor = switch proto.color {
                case .marked: .marked
                case .suspended: .suspended
                case .buried: .buried
                case .flagRed: .flagRed
                case .flagOrange: .flagOrange
                case .flagGreen: .flagGreen
                case .flagBlue: .flagBlue
                case .flagPink: .flagPink
                case .flagTurquoise: .flagTurquoise
                case .flagPurple: .flagPurple
                default: .normal
                }
                return BrowserRowData(
                    cells: cells,
                    color: color,
                    fontName: proto.fontName.isEmpty ? nil : proto.fontName,
                    fontSize: proto.fontSize == 0 ? nil : proto.fontSize
                )
            }
        )
    }

    private static func mirrorElide(_ e: Anki_Search_BrowserRow.Cell.TextElideMode) -> BrowserCellElide {
        switch e {
        case .elideLeft: .left
        case .elideMiddle: .middle
        case .elideNone: .none
        default: .right
        }
    }
}

// MARK: - sorted searches

/// Engine-side sort order for id searches — never sort client-side.
public struct SearchOrder: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No particular order (fastest).
        case none
        /// Raw user-typed order expression.
        case custom(String)
        /// Builtin column key from `AllBrowserColumns`, e.g. "noteCrt".
        case builtin(column: String, reverse: Bool)
    }
    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public static let none = SearchOrder(.none)

    var protoValue: Anki_Search_SortOrder {
        var order = Anki_Search_SortOrder()
        switch kind {
        case .none:
            order.none = Anki_Generic_Empty()
        case .custom(let expr):
            order.custom = expr
        case .builtin(let column, let reverse):
            order.builtin.column = column
            order.builtin.reverse = reverse
        }
        return order
    }
}
