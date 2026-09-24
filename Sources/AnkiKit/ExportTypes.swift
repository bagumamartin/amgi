public import Foundation

/// A scope accepted by Anki's export engine.
public enum ExportScope: Sendable, Hashable {
    case collection
    case deck(DeckID, name: String)
    case notes([NoteID], label: String)
    case cards([CardID], label: String)

    public var title: String {
        switch self {
        case .collection:
            "Whole collection"
        case .deck(_, let name):
            name
        case .notes(_, let label):
            label
        case .cards(_, let label):
            label
        }
    }

    public var detail: String {
        switch self {
        case .collection:
            "All decks, notes, cards, scheduling, and settings"
        case .deck:
            "One deck and its subdecks"
        case .notes(let ids, _):
            "\(ids.count) selected note\(ids.count == 1 ? "" : "s")"
        case .cards(let ids, _):
            "\(ids.count) selected card\(ids.count == 1 ? "" : "s")"
        }
    }

    public var itemCount: Int? {
        switch self {
        case .collection, .deck:
            nil
        case .notes(let ids, _):
            ids.count
        case .cards(let ids, _):
            ids.count
        }
    }
}

/// Compatibility name for callers that model Anki's protobuf `ExportLimit`.
public typealias ExportLimit = ExportScope

/// The built-in export formats exposed by desktop Anki.
public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case collectionPackage
    case deckPackage
    case noteText
    case cardText

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .collectionPackage: "Anki Collection Package"
        case .deckPackage: "Anki Deck Package"
        case .noteText: "Notes as Text"
        case .cardText: "Cards as Text"
        }
    }

    public var fileExtension: String {
        switch self {
        case .collectionPackage: "colpkg"
        case .deckPackage: "apkg"
        case .noteText, .cardText: "txt"
        }
    }
}

/// Options for `.apkg` exports.
public struct AnkiPackageExportOptions: Sendable, Equatable {
    public var includeScheduling: Bool
    public var includeDeckConfigurations: Bool
    public var includeMedia: Bool
    public var legacy: Bool

    public init(
        includeScheduling: Bool = false,
        includeDeckConfigurations: Bool = true,
        includeMedia: Bool = true,
        legacy: Bool = false
    ) {
        self.includeScheduling = includeScheduling
        self.includeDeckConfigurations = includeDeckConfigurations
        self.includeMedia = includeMedia
        self.legacy = legacy
    }
}

/// Options for Anki's note text exporter.
public struct NoteTextExportOptions: Sendable, Equatable {
    public var includeHTML: Bool
    public var includeTags: Bool
    public var includeDeck: Bool
    public var includeNotetype: Bool
    public var includeGUID: Bool

    public init(
        includeHTML: Bool = true,
        includeTags: Bool = false,
        includeDeck: Bool = false,
        includeNotetype: Bool = false,
        includeGUID: Bool = false
    ) {
        self.includeHTML = includeHTML
        self.includeTags = includeTags
        self.includeDeck = includeDeck
        self.includeNotetype = includeNotetype
        self.includeGUID = includeGUID
    }
}

/// Options for Anki's card text exporter.
public struct CardTextExportOptions: Sendable, Equatable {
    public var includeHTML: Bool

    public init(includeHTML: Bool = true) {
        self.includeHTML = includeHTML
    }
}

/// The count returned by an export operation.
public struct ExportResult: Sendable, Equatable {
    public let itemCount: Int
    public let url: URL

    public init(itemCount: Int, url: URL) {
        self.itemCount = itemCount
        self.url = url
    }
}
