import AnkiBackend
import AnkiProtoBridge
public import Foundation
public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct ImportExportService: Sendable {
    public var importAnkiPackage: @Sendable (_ path: String) throws -> String

    public var ankiPackageImportPresets: @Sendable () async throws -> AnkiPackageImportOptions
    public var importAnkiPackageWithOptions: @Sendable (
        _ path: String,
        _ options: AnkiPackageImportOptions
    ) async throws -> ImportLogSummary
    public var inspectPackage: @Sendable (_ path: String) async throws -> ImportPackageInspection

    public var csvImportMetadata: @Sendable (
        _ path: String,
        _ query: CSVImportMetadataQuery
    ) async throws -> CSVImportMetadata
    public var importCSV: @Sendable (
        _ path: String,
        _ metadata: CSVImportMetadata
    ) async throws -> ImportLogSummary
    public var importJSONFile: @Sendable (_ path: String) async throws -> ImportLogSummary

    public var inspectMnemosyne: @Sendable (_ path: String) async throws -> MnemosyneImportInspection
    public var importMnemosyne: @Sendable (
        _ path: String,
        _ deckName: String
    ) async throws -> ImportLogSummary

    public var importCollectionPackage: @Sendable (
        _ collectionPath: String,
        _ packagePath: String,
        _ mediaFolderPath: String,
        _ mediaDatabasePath: String
    ) async throws -> Void
    /// The raw engine RPC intentionally leaves the collection closed after
    /// exporting; callers that need to continue using the collection should
    /// prefer `exportCollectionPackageAndReopen`.
    public var exportCollectionPackage: @Sendable (_ outPath: String, _ includeMedia: Bool) throws -> Void
    public var exportCollectionPackageWithLegacy: @Sendable (
        _ outPath: String,
        _ includeMedia: Bool,
        _ legacy: Bool
    ) throws -> Void
    public var exportPackage: @Sendable (
        _ scope: ExportScope,
        _ outPath: String,
        _ options: AnkiPackageExportOptions
    ) throws -> UInt32
    public var exportNoteText: @Sendable (
        _ scope: ExportScope,
        _ outPath: String,
        _ options: NoteTextExportOptions
    ) throws -> UInt32
    public var exportCardText: @Sendable (
        _ scope: ExportScope,
        _ outPath: String,
        _ options: CardTextExportOptions
    ) throws -> UInt32
    public var exportCollectionPackageAndReopen: @Sendable (
        _ outPath: String,
        _ includeMedia: Bool,
        _ collectionPath: String,
        _ mediaFolderPath: String,
        _ mediaDatabasePath: String
    ) throws -> Void
    public var exportCollectionPackageAndReopenWithLegacy: @Sendable (
        _ outPath: String,
        _ includeMedia: Bool,
        _ legacy: Bool,
        _ collectionPath: String,
        _ mediaFolderPath: String,
        _ mediaDatabasePath: String
    ) throws -> Void
    public var exportDeckPackage: @Sendable (
        _ deckId: DeckID,
        _ outPath: String,
        _ withScheduling: Bool,
        _ withDeckConfigs: Bool,
        _ withMedia: Bool,
        _ legacy: Bool
    ) throws -> UInt32

    /// Export the entire current collection as an .apkg suitable for the merge
    /// flow (re-importable into another collection). Always includes media,
    /// scheduling, and deck configs.
    public var exportApkgForMerge: @Sendable (_ outPath: String) throws -> Void

    /// Import an .apkg into the current collection using merge-friendly
    /// options (merge notetypes, update notes/notetypes if newer). Returns
    /// the import log summary string.
    public var importApkgForMerge: @Sendable (_ path: String) throws -> String
    /// Export exactly the given notes to an .apkg. Returns exported count.
    public var exportNotesPackage: @Sendable (
        _ noteIds: [NoteID],
        _ outPath: String,
        _ withScheduling: Bool,
        _ withDeckConfigs: Bool,
        _ withMedia: Bool,
        _ legacy: Bool
    ) throws -> UInt32
    /// Export exactly the given cards to an .apkg. Returns exported count.
    public var exportCardsPackage: @Sendable (
        _ cardIds: [CardID],
        _ outPath: String,
        _ withScheduling: Bool,
        _ withDeckConfigs: Bool,
        _ withMedia: Bool,
        _ legacy: Bool
    ) throws -> UInt32
}

public struct CollectionExportReopenError: Error, LocalizedError, Sendable {
    public let outputPath: String
    public let underlyingDescription: String

    public init(outputPath: String, underlyingDescription: String) {
        self.outputPath = outputPath
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? {
        "The collection package was created, but Ijuka could not reopen the collection: \(underlyingDescription)"
    }
}

public extension ImportExportService {
    /// CSV-named aliases matching the backend methods. The exported files use
    /// Anki's tab-separated text format and `.txt` filenames in the UI.
    func exportNoteCsv(
        scope: ExportScope,
        outPath: String,
        options: NoteTextExportOptions
    ) throws -> UInt32 {
        try exportNoteText(scope: scope, outPath: outPath, options: options)
    }

    func exportCardCsv(
        scope: ExportScope,
        outPath: String,
        options: CardTextExportOptions
    ) throws -> UInt32 {
        try exportCardText(scope: scope, outPath: outPath, options: options)
    }
}

private func exportCollectionAndReopen(
    backend: AnkiBackend,
    outPath: String,
    includeMedia: Bool,
    legacy: Bool,
    collectionPath: String,
    mediaFolderPath: String,
    mediaDatabasePath: String
) throws {
    try backend.withLifecycleAccess {
        do {
            try backend.invoke(.exportCollectionPackage(
                outPath: outPath,
                includeMedia: includeMedia,
                legacy: legacy
            ))
        } catch {
            // The engine export RPC takes the collection out of the backend
            // before writing. Normalize early-failure and already-closed
            // states before surfacing the export error. If that recovery open
            // also fails, return a structured lifecycle error so the caller
            // can preserve any partial output and show the busy/recovery UI.
            let exportDescription = error.localizedDescription
            try? backend.closeCollection()
            do {
                try backend.openCollection(
                    collectionPath: collectionPath,
                    mediaFolderPath: mediaFolderPath,
                    mediaDbPath: mediaDatabasePath
                )
            } catch {
                throw CollectionExportReopenError(
                    outputPath: outPath,
                    underlyingDescription: "Export failed: \(exportDescription). Reopen failed: \(error.localizedDescription)"
                )
            }
            throw error
        }
        do {
            try backend.openCollection(
                collectionPath: collectionPath,
                mediaFolderPath: mediaFolderPath,
                mediaDbPath: mediaDatabasePath
            )
        } catch {
            throw CollectionExportReopenError(
                outputPath: outPath,
                underlyingDescription: error.localizedDescription
            )
        }
    }
}

extension ImportExportService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            importAnkiPackage: { path in
                let log = try backend.invoke(.importAnkiPackage(path: path))
                return "Imported: \(log.newCount) new, \(log.updatedCount) updated, \(log.duplicateCount) duplicates"
            },
            ankiPackageImportPresets: {
                try await backend.invoke(.ankiPackageImportPresets())
            },
            importAnkiPackageWithOptions: { path, options in
                try await backend.invoke(.importAnkiPackage(path: path, options: options))
            },
            inspectPackage: { path in
                try await backend.invoke(.inspectAnkiPackage(path: path))
            },
            csvImportMetadata: { path, query in
                try await backend.invoke(.csvImportMetadata(path: path, query: query))
            },
            importCSV: { path, metadata in
                try await backend.invoke(.importCSV(path: path, metadata: metadata))
            },
            importJSONFile: { path in
                try await backend.invoke(.importJSONFile(path: path))
            },
            inspectMnemosyne: { path in
                try await backend.invoke(.inspectMnemosyne(path: path))
            },
            importMnemosyne: { path, deckName in
                try await backend.invoke(.importMnemosyne(path: path, deckName: deckName))
            },
            importCollectionPackage: { collectionPath, packagePath, mediaFolderPath, mediaDatabasePath in
                try await backend.invoke(.importCollectionPackage(
                    collectionPath: collectionPath,
                    packagePath: packagePath,
                    mediaFolderPath: mediaFolderPath,
                    mediaDatabasePath: mediaDatabasePath
                ))
            },
            exportCollectionPackage: { outPath, includeMedia in
                try backend.invoke(.exportCollectionPackage(outPath: outPath, includeMedia: includeMedia))
            },
            exportCollectionPackageWithLegacy: { outPath, includeMedia, legacy in
                try backend.invoke(.exportCollectionPackage(
                    outPath: outPath,
                    includeMedia: includeMedia,
                    legacy: legacy
                ))
            },
            exportPackage: { scope, outPath, options in
                try backend.invoke(.exportAnkiPackage(scope: scope, outPath: outPath, options: options))
            },
            exportNoteText: { scope, outPath, options in
                try backend.invoke(.exportNoteText(scope: scope, outPath: outPath, options: options))
            },
            exportCardText: { scope, outPath, options in
                try backend.invoke(.exportCardText(scope: scope, outPath: outPath, options: options))
            },
            exportCollectionPackageAndReopen: {
                outPath, includeMedia, collectionPath, mediaFolderPath, mediaDatabasePath in
                try exportCollectionAndReopen(
                    backend: backend,
                    outPath: outPath,
                    includeMedia: includeMedia,
                    legacy: false,
                    collectionPath: collectionPath,
                    mediaFolderPath: mediaFolderPath,
                    mediaDatabasePath: mediaDatabasePath
                )
            },
            exportCollectionPackageAndReopenWithLegacy: {
                outPath, includeMedia, legacy, collectionPath, mediaFolderPath, mediaDatabasePath in
                try exportCollectionAndReopen(
                    backend: backend,
                    outPath: outPath,
                    includeMedia: includeMedia,
                    legacy: legacy,
                    collectionPath: collectionPath,
                    mediaFolderPath: mediaFolderPath,
                    mediaDatabasePath: mediaDatabasePath
                )
            },
            exportDeckPackage: { deckId, outPath, withScheduling, withDeckConfigs, withMedia, legacy in
                try backend.invoke(.exportAnkiPackage(
                    deckId: deckId,
                    outPath: outPath,
                    withScheduling: withScheduling,
                    withDeckConfigs: withDeckConfigs,
                    withMedia: withMedia,
                    legacy: legacy
                ))
            },
            exportApkgForMerge: { outPath in
                try backend.invoke(.exportAnkiPackageForMerge(outPath: outPath))
            },
            importApkgForMerge: { path in
                let log = try backend.invoke(.importAnkiPackageForMerge(path: path))
                return "Merged: \(log.newCount) new, \(log.updatedCount) updated, \(log.duplicateCount) duplicates"
            },
            exportNotesPackage: { noteIds, outPath, withScheduling, withDeckConfigs, withMedia, legacy in
                try backend.invoke(.exportAnkiPackage(
                    noteIds: noteIds,
                    outPath: outPath,
                    withScheduling: withScheduling,
                    withDeckConfigs: withDeckConfigs,
                    withMedia: withMedia,
                    legacy: legacy
                ))
            },
            exportCardsPackage: { cardIds, outPath, withScheduling, withDeckConfigs, withMedia, legacy in
                try backend.invoke(.exportAnkiPackage(
                    cardIds: cardIds,
                    outPath: outPath,
                    withScheduling: withScheduling,
                    withDeckConfigs: withDeckConfigs,
                    withMedia: withMedia,
                    legacy: legacy
                ))
            }
        )
    }()
}

extension ImportExportService: TestDependencyKey {
    public static let testValue = ImportExportService()
}

extension DependencyValues {
    public var importExportService: ImportExportService {
        get { self[ImportExportService.self] }
        set { self[ImportExportService.self] = newValue }
    }
}
