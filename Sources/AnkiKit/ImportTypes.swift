import Foundation

/// Controls how an imported Anki package handles an existing note.
public enum ImportPackageUpdateCondition: Int, Sendable, Equatable, CaseIterable {
    case ifNewer
    case always
    case never
}

/// Options shown by Anki's package-import review screen.
public struct AnkiPackageImportOptions: Sendable, Equatable {
    public var mergeNotetypes: Bool
    public var updateNotes: ImportPackageUpdateCondition
    public var updateNotetypes: ImportPackageUpdateCondition
    public var withScheduling: Bool
    public var withDeckConfigs: Bool

    public init(
        mergeNotetypes: Bool = false,
        updateNotes: ImportPackageUpdateCondition = .ifNewer,
        updateNotetypes: ImportPackageUpdateCondition = .ifNewer,
        withScheduling: Bool = false,
        withDeckConfigs: Bool = false
    ) {
        self.mergeNotetypes = mergeNotetypes
        self.updateNotes = updateNotes
        self.updateNotetypes = updateNotetypes
        self.withScheduling = withScheduling
        self.withDeckConfigs = withDeckConfigs
    }
}

/// Counts returned by every note-producing Anki importer.
public struct ImportLogSummary: Sendable, Equatable {
    public let foundNotes: Int
    public let newCount: Int
    public let updatedCount: Int
    public let duplicateCount: Int
    public let conflictingCount: Int
    public let firstFieldMatchCount: Int
    public let missingNotetypeCount: Int
    public let missingDeckCount: Int
    public let emptyFirstFieldCount: Int

    public init(
        foundNotes: Int = 0,
        newCount: Int,
        updatedCount: Int,
        duplicateCount: Int,
        conflictingCount: Int = 0,
        firstFieldMatchCount: Int = 0,
        missingNotetypeCount: Int = 0,
        missingDeckCount: Int = 0,
        emptyFirstFieldCount: Int = 0
    ) {
        self.foundNotes = foundNotes
        self.newCount = newCount
        self.updatedCount = updatedCount
        self.duplicateCount = duplicateCount
        self.conflictingCount = conflictingCount
        self.firstFieldMatchCount = firstFieldMatchCount
        self.missingNotetypeCount = missingNotetypeCount
        self.missingDeckCount = missingDeckCount
        self.emptyFirstFieldCount = emptyFirstFieldCount
    }

    public var importedCount: Int {
        newCount + updatedCount
    }

    public var problemCount: Int {
        conflictingCount
            + firstFieldMatchCount
            + missingNotetypeCount
            + missingDeckCount
            + emptyFirstFieldCount
    }
}

/// The one-character separators supported by Anki's text importer.
public enum ImportDelimiter: Int, Sendable, Equatable, CaseIterable {
    case tab
    case pipe
    case semicolon
    case colon
    case comma
    case space
}

/// What Anki should do when a text/JSON import matches an existing note.
public enum ImportDuplicateResolution: Int, Sendable, Equatable, CaseIterable {
    case update
    case preserve
    case duplicate
}

/// Controls whether duplicate detection considers only the note type or also the deck.
public enum ImportMatchScope: Int, Sendable, Equatable, CaseIterable {
    case notetype
    case notetypeAndDeck
}

/// Destination selected by Anki's text importer.
public enum ImportDeckTarget: Sendable, Equatable {
    case deck(DeckID)
    case column(Int)
    case newDeck(String)
}

/// A note type plus its one-based source-column mapping (`0` means ignored).
public struct MappedImportNotetype: Sendable, Equatable {
    public var id: NotetypeID
    public var fieldColumns: [Int]

    public init(id: NotetypeID, fieldColumns: [Int]) {
        self.id = id
        self.fieldColumns = fieldColumns
    }
}

/// Whether all rows use one mapping or select a note type from a column.
public enum ImportNotetypeTarget: Sendable, Equatable {
    case global(MappedImportNotetype)
    case column(Int)
}

/// Backend-independent mirror of Anki's text-import metadata.
public struct CSVImportMetadata: Sendable, Equatable {
    public var delimiter: ImportDelimiter
    public var isHTML: Bool
    public var globalTags: [String]
    public var updatedTags: [String]
    public var columnLabels: [String]
    public var deck: ImportDeckTarget
    public var notetype: ImportNotetypeTarget
    public var tagsColumn: Int
    public var forceDelimiter: Bool
    public var forceIsHTML: Bool
    public var preview: [[String]]
    public var guidColumn: Int
    public var duplicateResolution: ImportDuplicateResolution
    public var matchScope: ImportMatchScope

    public init(
        delimiter: ImportDelimiter = .tab,
        isHTML: Bool = false,
        globalTags: [String] = [],
        updatedTags: [String] = [],
        columnLabels: [String] = [],
        deck: ImportDeckTarget = .newDeck(""),
        notetype: ImportNotetypeTarget = .global(.init(id: NotetypeID(0), fieldColumns: [])),
        tagsColumn: Int = 0,
        forceDelimiter: Bool = false,
        forceIsHTML: Bool = false,
        preview: [[String]] = [],
        guidColumn: Int = 0,
        duplicateResolution: ImportDuplicateResolution = .update,
        matchScope: ImportMatchScope = .notetype
    ) {
        self.delimiter = delimiter
        self.isHTML = isHTML
        self.globalTags = globalTags
        self.updatedTags = updatedTags
        self.columnLabels = columnLabels
        self.deck = deck
        self.notetype = notetype
        self.tagsColumn = tagsColumn
        self.forceDelimiter = forceDelimiter
        self.forceIsHTML = forceIsHTML
        self.preview = preview
        self.guidColumn = guidColumn
        self.duplicateResolution = duplicateResolution
        self.matchScope = matchScope
    }
}

/// Optional constraints used while asking Anki to inspect a text file.
public struct CSVImportMetadataQuery: Sendable, Equatable {
    public var delimiter: ImportDelimiter?
    public var notetypeID: NotetypeID?
    public var deckID: DeckID?
    public var isHTML: Bool?

    public init(
        delimiter: ImportDelimiter? = nil,
        notetypeID: NotetypeID? = nil,
        deckID: DeckID? = nil,
        isHTML: Bool? = nil
    ) {
        self.delimiter = delimiter
        self.notetypeID = notetypeID
        self.deckID = deckID
        self.isHTML = isHTML
    }
}

/// Read-only package facts shown before a deck or collection is changed.
public struct ImportPackageInspection: Sendable, Equatable, Codable {
    public let formatVersion: Int
    public let noteCount: Int
    public let cardCount: Int
    public let notetypeCount: Int
    public let reviewCount: Int
    public let deckNames: [String]
    public let mediaCount: Int
    public let archiveEntryCount: Int
    public let isCollectionBackup: Bool

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case noteCount
        case cardCount
        case notetypeCount
        case reviewCount
        case deckNames
        case mediaCount
        case archiveEntryCount
        case isCollectionBackup
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        noteCount = try container.decode(Int.self, forKey: .noteCount)
        cardCount = try container.decode(Int.self, forKey: .cardCount)
        notetypeCount = try container.decode(Int.self, forKey: .notetypeCount)
        reviewCount = try container.decode(Int.self, forKey: .reviewCount)
        deckNames = try container.decode([String].self, forKey: .deckNames)
        mediaCount = try container.decode(Int.self, forKey: .mediaCount)
        archiveEntryCount = try container.decode(Int.self, forKey: .archiveEntryCount)
        isCollectionBackup = try container.decodeIfPresent(Bool.self, forKey: .isCollectionBackup) ?? false
    }

    public init(
        formatVersion: Int,
        noteCount: Int,
        cardCount: Int,
        notetypeCount: Int,
        reviewCount: Int,
        deckNames: [String],
        mediaCount: Int,
        archiveEntryCount: Int,
        isCollectionBackup: Bool = false
    ) {
        self.formatVersion = formatVersion
        self.noteCount = noteCount
        self.cardCount = cardCount
        self.notetypeCount = notetypeCount
        self.reviewCount = reviewCount
        self.deckNames = deckNames
        self.mediaCount = mediaCount
        self.archiveEntryCount = archiveEntryCount
        self.isCollectionBackup = isCollectionBackup
    }
}

/// Read-only Mnemosyne facts shown before conversion to Anki notes.
public struct MnemosyneImportInspection: Sendable, Equatable, Codable {
    public let version: String
    public let noteCount: Int
    public let cardCount: Int
    public let factViewCounts: [String: Int]

    public init(
        version: String,
        noteCount: Int,
        cardCount: Int,
        factViewCounts: [String: Int]
    ) {
        self.version = version
        self.noteCount = noteCount
        self.cardCount = cardCount
        self.factViewCounts = factViewCounts
    }
}
