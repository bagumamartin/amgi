import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - importAnkiPackage

extension Request where Response == ImportLogSummary {
    /// Imports an .apkg at `path` and returns a summary of how many
    /// notes were created, updated, and skipped as duplicates.
    public static func importAnkiPackage(path: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ImportAnkiPackageRequest()
                proto.packagePath = path
                return try proto.serializedData()
            },
            decode: decodeImportLog
        )
    }
}

private func decodeImportLog(_ bytes: Data) throws -> ImportLogSummary {
    let response = try Anki_ImportExport_ImportResponse(serializedBytes: bytes)
    let log = response.log
    return ImportLogSummary(
        foundNotes: Int(log.foundNotes),
        newCount: log.new.count,
        updatedCount: log.updated.count,
        duplicateCount: log.duplicate.count,
        conflictingCount: log.conflicting.count,
        firstFieldMatchCount: log.firstFieldMatch.count,
        missingNotetypeCount: log.missingNotetype.count,
        missingDeckCount: log.missingDeck.count,
        emptyFirstFieldCount: log.emptyFirstField.count
    )
}

private extension Anki_ImportExport_CsvMetadata {
    var importMetadata: CSVImportMetadata {
        let deckTarget: ImportDeckTarget
        switch deck {
        case .deckID(let id):
            deckTarget = .deck(DeckID(id))
        case .deckColumn(let column):
            deckTarget = .column(Int(column))
        case .deckName(let name):
            deckTarget = .newDeck(name)
        case nil:
            deckTarget = .newDeck("")
        }

        let notetypeTarget: ImportNotetypeTarget
        switch notetype {
        case .globalNotetype(let mapped):
            notetypeTarget = .global(.init(
                id: NotetypeID(mapped.id),
                fieldColumns: mapped.fieldColumns.map(Int.init)
            ))
        case .notetypeColumn(let column):
            notetypeTarget = .column(Int(column))
        case nil:
            notetypeTarget = .global(.init(id: NotetypeID(0), fieldColumns: []))
        }

        return CSVImportMetadata(
            delimiter: ImportDelimiter(rawValue: delimiter.rawValue) ?? .tab,
            isHTML: isHtml,
            globalTags: globalTags,
            updatedTags: updatedTags,
            columnLabels: columnLabels,
            deck: deckTarget,
            notetype: notetypeTarget,
            tagsColumn: Int(tagsColumn),
            forceDelimiter: forceDelimiter,
            forceIsHTML: forceIsHtml,
            preview: preview.map(\.vals),
            guidColumn: Int(guidColumn),
            duplicateResolution: ImportDuplicateResolution(rawValue: dupeResolution.rawValue) ?? .update,
            matchScope: ImportMatchScope(rawValue: matchScope.rawValue) ?? .notetype
        )
    }

    init(importMetadata: CSVImportMetadata) {
        self.init()
        delimiter = Anki_ImportExport_CsvMetadata.Delimiter(
            rawValue: importMetadata.delimiter.rawValue
        ) ?? .tab
        isHtml = importMetadata.isHTML
        globalTags = importMetadata.globalTags
        updatedTags = importMetadata.updatedTags
        columnLabels = importMetadata.columnLabels

        switch importMetadata.deck {
        case .deck(let id):
            deckID = id.rawValue
        case .column(let column):
            deckColumn = UInt32(max(0, column))
        case .newDeck(let name):
            deckName = name
        }

        switch importMetadata.notetype {
        case .global(let mapped):
            var proto = Anki_ImportExport_CsvMetadata.MappedNotetype()
            proto.id = mapped.id.rawValue
            proto.fieldColumns = mapped.fieldColumns.map { UInt32(max(0, $0)) }
            globalNotetype = proto
        case .column(let column):
            notetypeColumn = UInt32(max(0, column))
        }

        tagsColumn = UInt32(max(0, importMetadata.tagsColumn))
        forceDelimiter = importMetadata.forceDelimiter
        forceIsHtml = importMetadata.forceIsHTML
        preview = importMetadata.preview.map { values in
            var list = Anki_Generic_StringList()
            list.vals = values
            return list
        }
        guidColumn = UInt32(max(0, importMetadata.guidColumn))
        dupeResolution = Anki_ImportExport_CsvMetadata.DupeResolution(
            rawValue: importMetadata.duplicateResolution.rawValue
        ) ?? .update
        matchScope = Anki_ImportExport_CsvMetadata.MatchScope(
            rawValue: importMetadata.matchScope.rawValue
        ) ?? .notetype
    }
}

private extension CSVImportMetadata {
    var csvProto: Anki_ImportExport_CsvMetadata {
        Anki_ImportExport_CsvMetadata(importMetadata: self)
    }
}

// MARK: - Anki package import options

extension Request where Response == AnkiPackageImportOptions {
    /// Returns the collection's last-used package import settings.
    public static func ankiPackageImportPresets() -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.getImportAnkiPackagePresets,
            encode: { Data() },
            decode: { bytes in
                let options = try Anki_ImportExport_ImportAnkiPackageOptions(serializedBytes: bytes)
                return AnkiPackageImportOptions(
                    mergeNotetypes: options.mergeNotetypes,
                    updateNotes: ImportPackageUpdateCondition(rawValue: options.updateNotes.rawValue) ?? .ifNewer,
                    updateNotetypes: ImportPackageUpdateCondition(rawValue: options.updateNotetypes.rawValue) ?? .ifNewer,
                    withScheduling: options.withScheduling,
                    withDeckConfigs: options.withDeckConfigs
                )
            }
        )
    }
}

extension Request where Response == ImportLogSummary {
    /// Imports a deck package using the options confirmed on the review screen.
    public static func importAnkiPackage(
        path: String,
        options: AnkiPackageImportOptions
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importAnkiPackage,
            encode: {
                var request = Anki_ImportExport_ImportAnkiPackageRequest()
                request.packagePath = path

                var protoOptions = Anki_ImportExport_ImportAnkiPackageOptions()
                protoOptions.mergeNotetypes = options.mergeNotetypes
                protoOptions.updateNotes = Anki_ImportExport_ImportAnkiPackageUpdateCondition(
                    rawValue: options.updateNotes.rawValue
                ) ?? .ifNewer
                protoOptions.updateNotetypes = Anki_ImportExport_ImportAnkiPackageUpdateCondition(
                    rawValue: options.updateNotetypes.rawValue
                ) ?? .ifNewer
                protoOptions.withScheduling = options.withScheduling
                protoOptions.withDeckConfigs = options.withDeckConfigs
                request.options = protoOptions
                return try request.serializedData()
            },
            decode: decodeImportLog
        )
    }
}

// MARK: - Text/CSV import

extension Request where Response == CSVImportMetadata {
    /// Parses the first rows of a text file and asks Anki to propose a mapping.
    public static func csvImportMetadata(
        path: String,
        query: CSVImportMetadataQuery
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.getCSVMetadata,
            encode: {
                var request = Anki_ImportExport_CsvMetadataRequest()
                request.path = path
                if let delimiter = query.delimiter {
                    request.delimiter = Anki_ImportExport_CsvMetadata.Delimiter(
                        rawValue: delimiter.rawValue
                    ) ?? .tab
                }
                if let notetypeID = query.notetypeID {
                    request.notetypeID = notetypeID.rawValue
                }
                if let deckID = query.deckID {
                    request.deckID = deckID.rawValue
                }
                if let isHTML = query.isHTML {
                    request.isHtml = isHTML
                }
                return try request.serializedData()
            },
            decode: { bytes in
                try Anki_ImportExport_CsvMetadata(serializedBytes: bytes).importMetadata
            }
        )
    }
}

extension Request where Response == ImportLogSummary {
    /// Imports a reviewed CSV/TSV/TXT mapping.
    public static func importCSV(path: String, metadata: CSVImportMetadata) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importCSV,
            encode: {
                var request = Anki_ImportExport_ImportCsvRequest()
                request.path = path
                request.metadata = metadata.csvProto
                return try request.serializedData()
            },
            decode: decodeImportLog
        )
    }
}

// MARK: - Anki JSON import

extension Request where Response == ImportLogSummary {
    public static func importJSONFile(path: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importJSONFile,
            encode: {
                var request = Anki_Generic_String()
                request.val = path
                return try request.serializedData()
            },
            decode: decodeImportLog
        )
    }
}

// MARK: - Collection package import

extension Request where Response == Void {
    /// Replaces the current collection with a `.colpkg` backup.
    public static func importCollectionPackage(
        collectionPath: String,
        packagePath: String,
        mediaFolderPath: String,
        mediaDatabasePath: String
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importCollectionPackage,
            encode: {
                var request = Anki_ImportExport_ImportCollectionPackageRequest()
                request.colPath = collectionPath
                request.backupPath = packagePath
                request.mediaFolder = mediaFolderPath
                request.mediaDb = mediaDatabasePath
                return try request.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - importAnkiPackageForMerge

extension Request where Response == ImportLogSummary {
    /// Imports an .apkg using merge-friendly options: notetypes are merged
    /// and notes/notetypes update when the incoming copy is newer. Used by
    /// the sync merge flow to fold a local backup into a freshly-downloaded
    /// server collection.
    public static func importAnkiPackageForMerge(path: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ImportAnkiPackageRequest()
                proto.packagePath = path

                var options = Anki_ImportExport_ImportAnkiPackageOptions()
                options.mergeNotetypes = true
                options.withScheduling = true
                options.withDeckConfigs = true
                options.updateNotes = .ifNewer
                options.updateNotetypes = .ifNewer
                proto.options = options

                return try proto.serializedData()
            },
            decode: decodeImportLog
        )
    }
}

// MARK: - exportAnkiPackageForMerge (whole collection)

extension Request where Response == Void {
    /// Exports the entire collection as an .apkg suitable for the sync merge
    /// flow (re-importable into another collection). Always includes media,
    /// scheduling, and deck configs.
    public static func exportAnkiPackageForMerge(outPath: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var options = Anki_ImportExport_ExportAnkiPackageOptions()
                options.withScheduling = true
                options.withDeckConfigs = true
                options.withMedia = true
                options.legacy = false
                proto.options = options

                var limit = Anki_ImportExport_ExportLimit()
                limit.limit = .wholeCollection(Anki_Generic_Empty())
                proto.limit = limit

                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - exportAnkiPackage (note / card selection)

extension Request where Response == UInt32 {
    /// Exports exactly the given notes to an .apkg at `outPath`. Returns the
    /// number of notes exported. Powers Browse selection export without
    /// touching the collection (no temp-deck move; `ExportLimit.note_ids`).
    public static func exportAnkiPackage(
        noteIds: [NoteID],
        outPath: String,
        withScheduling: Bool,
        withDeckConfigs: Bool,
        withMedia: Bool,
        legacy: Bool
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var options = Anki_ImportExport_ExportAnkiPackageOptions()
                options.withScheduling = withScheduling
                options.withDeckConfigs = withDeckConfigs
                options.withMedia = withMedia
                options.legacy = legacy
                proto.options = options

                var limit = Anki_ImportExport_ExportLimit()
                var ids = Anki_Notes_NoteIds()
                ids.noteIds = noteIds.map(\.rawValue)
                limit.noteIds = ids
                proto.limit = limit

                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_Generic_UInt32(serializedBytes: bytes)
                return resp.val
            }
        )
    }

    /// Exports exactly the given cards (same `ExportLimit` oneof, `card_ids`
    /// arm). Used when the Browse selection is card-scoped.
    public static func exportAnkiPackage(
        cardIds: [CardID],
        outPath: String,
        withScheduling: Bool,
        withDeckConfigs: Bool,
        withMedia: Bool,
        legacy: Bool
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var options = Anki_ImportExport_ExportAnkiPackageOptions()
                options.withScheduling = withScheduling
                options.withDeckConfigs = withDeckConfigs
                options.withMedia = withMedia
                options.legacy = legacy
                proto.options = options

                var limit = Anki_ImportExport_ExportLimit()
                var ids = Anki_Cards_CardIds()
                ids.cids = cardIds.map(\.rawValue)
                limit.cardIds = ids
                proto.limit = limit

                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_Generic_UInt32(serializedBytes: bytes)
                return resp.val
            }
        )
    }
}

// MARK: - exportCollectionPackage

extension Request where Response == Void {
    /// Writes a full collection .colpkg to `outPath`. `includeMedia`
    /// controls whether media files are bundled.
    public static func exportCollectionPackage(
        outPath: String,
        includeMedia: Bool,
        legacy: Bool = false
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportCollectionPackage,
            encode: {
                var proto = Anki_ImportExport_ExportCollectionPackageRequest()
                proto.outPath = outPath
                proto.includeMedia = includeMedia
                proto.legacy = legacy
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

private func exportLimit(for scope: ExportScope) -> Anki_ImportExport_ExportLimit {
    var limit = Anki_ImportExport_ExportLimit()
    switch scope {
    case .collection:
        limit.wholeCollection = Anki_Generic_Empty()
    case .deck(let id, _):
        limit.deckID = id.rawValue
    case .notes(let ids, _):
        var noteIDs = Anki_Notes_NoteIds()
        noteIDs.noteIds = ids.map(\.rawValue)
        limit.noteIds = noteIDs
    case .cards(let ids, _):
        var cardIDs = Anki_Cards_CardIds()
        cardIDs.cids = ids.map(\.rawValue)
        limit.cardIds = cardIDs
    }
    return limit
}

// MARK: - exportAnkiPackage (scope-driven)

extension Request where Response == UInt32 {
    public static func exportAnkiPackage(
        scope: ExportScope,
        outPath: String,
        options: AnkiPackageExportOptions
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var protoOptions = Anki_ImportExport_ExportAnkiPackageOptions()
                protoOptions.withScheduling = options.includeScheduling
                protoOptions.withDeckConfigs = options.includeDeckConfigurations
                protoOptions.withMedia = options.includeMedia
                protoOptions.legacy = options.legacy
                proto.options = protoOptions
                proto.limit = exportLimit(for: scope)
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_UInt32(serializedBytes: bytes).val
            }
        )
    }
}

// MARK: - export text formats

extension Request where Response == UInt32 {
    public static func exportNoteText(
        scope: ExportScope,
        outPath: String,
        options: NoteTextExportOptions
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportNoteCSV,
            encode: {
                var proto = Anki_ImportExport_ExportNoteCsvRequest()
                proto.outPath = outPath
                proto.withHtml = options.includeHTML
                proto.withTags = options.includeTags
                proto.withDeck = options.includeDeck
                proto.withNotetype = options.includeNotetype
                proto.withGuid = options.includeGUID
                proto.limit = exportLimit(for: scope)
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_UInt32(serializedBytes: bytes).val
            }
        )
    }

    public static func exportCardText(
        scope: ExportScope,
        outPath: String,
        options: CardTextExportOptions
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportCardCSV,
            encode: {
                var proto = Anki_ImportExport_ExportCardCsvRequest()
                proto.outPath = outPath
                proto.withHtml = options.includeHTML
                proto.limit = exportLimit(for: scope)
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_UInt32(serializedBytes: bytes).val
            }
        )
    }
}


extension Request where Response == UInt32 {
    /// CSV is the wire-format name used by Anki's backend; the UI calls
    /// these text exports because their output is tab-separated UTF-8 text.
    public static func exportNoteCsv(
        scope: ExportScope,
        outPath: String,
        options: NoteTextExportOptions
    ) -> Self {
        Self.exportNoteText(scope: scope, outPath: outPath, options: options)
    }

    public static func exportCardCsv(
        scope: ExportScope,
        outPath: String,
        options: CardTextExportOptions
    ) -> Self {
        Self.exportCardText(scope: scope, outPath: outPath, options: options)
    }

    /// Exports a single deck to an .apkg at `outPath`. Returns the
    /// number of notes exported. `legacy: true` produces an old-format
    /// package compatible with Anki <2.1.50.
    public static func exportAnkiPackage(
        deckId: DeckID,
        outPath: String,
        withScheduling: Bool,
        withDeckConfigs: Bool,
        withMedia: Bool,
        legacy: Bool
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var options = Anki_ImportExport_ExportAnkiPackageOptions()
                options.withScheduling = withScheduling
                options.withDeckConfigs = withDeckConfigs
                options.withMedia = withMedia
                options.legacy = legacy
                proto.options = options

                var limit = Anki_ImportExport_ExportLimit()
                limit.deckID = deckId.rawValue
                proto.limit = limit

                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_Generic_UInt32(serializedBytes: bytes)
                return resp.val
            }
        )
    }
}
