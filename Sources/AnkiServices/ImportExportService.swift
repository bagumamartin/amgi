import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct ImportExportService: Sendable {
    public var importAnkiPackage: @Sendable (_ path: String) throws -> String
    public var exportCollectionPackage: @Sendable (_ outPath: String, _ includeMedia: Bool) throws -> Void
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

extension ImportExportService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            importAnkiPackage: { path in
                let log = try backend.invoke(.importAnkiPackage(path: path))
                return "Imported: \(log.newCount) new, \(log.updatedCount) updated, \(log.duplicateCount) duplicates"
            },
            exportCollectionPackage: { outPath, includeMedia in
                try backend.invoke(.exportCollectionPackage(outPath: outPath, includeMedia: includeMedia))
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
