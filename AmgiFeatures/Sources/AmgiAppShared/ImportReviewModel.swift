package import Foundation
import AnkiServices
package import AnkiKit
import Dependencies
package import Observation

package enum ImportReviewPhase: Equatable, Sendable {
    case preparing
    case review
    case importing
    case completed
    case failed
}

package struct AnkiJSONImportSummary: Sendable, Equatable {
    package let noteCount: Int
    package let cardCount: Int
    package let notetypeCount: Int
    package let globalTagCount: Int
    package let defaultDeck: String?

    package init(
        noteCount: Int,
        cardCount: Int,
        notetypeCount: Int,
        globalTagCount: Int,
        defaultDeck: String?
    ) {
        self.noteCount = noteCount
        self.cardCount = cardCount
        self.notetypeCount = notetypeCount
        self.globalTagCount = globalTagCount
        self.defaultDeck = defaultDeck
    }
}

@MainActor
@Observable
package final class ImportReviewModel {
    package private(set) var phase: ImportReviewPhase = .preparing
    package private(set) var format: AnkiImportFormat?
    package private(set) var sourceName: String
    package private(set) var sourceByteCount: Int64?
    package private(set) var failureMessage: String?
    package private(set) var completionSummary: ImportLogSummary?

    package var packageInspection: ImportPackageInspection?
    package var packageOptions = AnkiPackageImportOptions()
    package var csvMetadata: CSVImportMetadata?
    package var globalTagsDraft = ""
    package var updatedTagsDraft = ""
    package var notetypeFields: [String] = []
    package var decks: [DeckInfo] = []
    package var notetypes: [NotetypeNameId] = []
    package var mnemosyneInspection: MnemosyneImportInspection?
    package var mnemosyneDeckName = ""
    package var jsonSummary: AnkiJSONImportSummary?

    @ObservationIgnored private let sourceURL: URL
    @ObservationIgnored private let replaceCollection: @MainActor @Sendable (URL) async throws -> Void
    @ObservationIgnored private let onComplete: @MainActor @Sendable () -> Void
    @ObservationIgnored private var stagedURL: URL?
    @ObservationIgnored private var stagingDirectory: URL?
    @ObservationIgnored private var hasPrepared = false

    @ObservationIgnored @Dependency(\.importExportService) private var importExportService
    @ObservationIgnored @Dependency(\.decksService) private var decksService
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService

    package init(
        sourceURL: URL,
        replaceCollection: @escaping @MainActor @Sendable (URL) async throws -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        self.sourceURL = sourceURL
        self.sourceName = sourceURL.lastPathComponent
        self.replaceCollection = replaceCollection
        self.onComplete = onComplete
    }

    package var navigationTitle: String {
        switch phase {
        case .preparing: "Import"
        case .review: format?.title ?? "Import"
        case .importing: "Importing"
        case .completed: "Import Complete"
        case .failed: "Can’t Import File"
        }
    }

    package var primaryActionTitle: String {
        format?.replacesCollection == true ? "Replace Collection" : "Import"
    }

    package var canImport: Bool {
        guard phase == .review else { return false }
        guard let format else { return false }
        switch format {
        case .deckPackage, .collectionPackage, .zippedPackage, .ankiJSON:
            return true
        case .text:
            guard let metadata = csvMetadata, !metadata.preview.isEmpty else { return false }
            if case .newDeck(let name) = metadata.deck,
               name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            guard case .global(let mapped) = metadata.notetype else { return true }
            return (mapped.fieldColumns.first ?? 0) != 0
        case .mnemosyne:
            return !mnemosyneDeckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    package func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        phase = .preparing
        failureMessage = nil
        completionSummary = nil

        do {
            let staged = try await Self.stage(sourceURL: sourceURL)
            stagedURL = staged.url
            stagingDirectory = staged.directory
            sourceName = staged.url.lastPathComponent
            sourceByteCount = staged.byteCount
            guard let format = AnkiImportFormat(url: staged.url) else {
                throw ImportReviewFailure.unsupported(sourceURL.pathExtension)
            }
            self.format = format
            try await loadReview(for: format, path: staged.url.path)
            phase = .review
        } catch {
            phase = .failed
            failureMessage = Self.message(for: error, format: format)
        }
    }

    package func retry() async {
        cleanup()
        hasPrepared = false
        await prepare()
    }

    package func cleanup() {
        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        stagingDirectory = nil
        stagedURL = nil
    }

    package func importNow() async {
        guard canImport, let format, let stagedURL else { return }
        phase = .importing
        failureMessage = nil

        do {
            let summary = try await executeImport(format: format, path: stagedURL.path)
            completionSummary = summary
            phase = .completed
            onComplete()
        } catch {
            phase = .failed
            failureMessage = Self.message(for: error, format: format)
        }
    }

    // MARK: - Package options

    package func setSchedulingIncluded(_ included: Bool) {
        packageOptions.withScheduling = included
    }

    package func setDeckConfigurationsIncluded(_ included: Bool) {
        packageOptions.withDeckConfigs = included
    }

    package func setMergeNoteTypes(_ merge: Bool) {
        packageOptions.mergeNotetypes = merge
    }

    package func setUpdateNotes(_ condition: ImportPackageUpdateCondition) {
        packageOptions.updateNotes = condition
    }

    package func setUpdateNoteTypes(_ condition: ImportPackageUpdateCondition) {
        packageOptions.updateNotetypes = condition
    }

    // MARK: - Text options

    package func updateTextFormat(
        delimiter: ImportDelimiter? = nil,
        isHTML: Bool? = nil
    ) async {
        guard var metadata = csvMetadata else { return }
        failureMessage = nil
        let tags = metadata.globalTags
        let updatedTags = metadata.updatedTags
        if let delimiter {
            metadata.delimiter = delimiter
            metadata.forceDelimiter = true
        }
        if let isHTML {
            metadata.isHTML = isHTML
            metadata.forceIsHTML = true
        }
        csvMetadata = metadata

        do {
            try await refreshCSVMetadata(preservingTags: true, tags: tags, updatedTags: updatedTags)
        } catch {
            failureMessage = Self.message(for: error, format: .text)
        }
    }

    package func selectNotetype(_ id: NotetypeID) async {
        guard var metadata = csvMetadata else { return }
        failureMessage = nil
        let tags = metadata.globalTags
        let updatedTags = metadata.updatedTags
        if case .global(let mapped) = metadata.notetype {
            metadata.notetype = .global(.init(id: id, fieldColumns: mapped.fieldColumns))
        } else {
            metadata.notetype = .global(.init(id: id, fieldColumns: []))
        }
        csvMetadata = metadata
        do {
            try await refreshCSVMetadata(preservingTags: true, tags: tags, updatedTags: updatedTags)
        } catch {
            failureMessage = Self.message(for: error, format: .text)
        }
    }

    package func setFieldMapping(fieldIndex: Int, column: Int) {
        guard var metadata = csvMetadata,
              case .global(var mapped) = metadata.notetype,
              fieldIndex >= 0,
              fieldIndex < mapped.fieldColumns.count
        else { return }
        mapped.fieldColumns[fieldIndex] = max(0, column)
        metadata.notetype = .global(mapped)
        csvMetadata = metadata
    }

    package func setTagsColumn(_ column: Int) {
        guard var metadata = csvMetadata else { return }
        metadata.tagsColumn = max(0, column)
        csvMetadata = metadata
    }

    package func setDuplicateResolution(_ resolution: ImportDuplicateResolution) {
        guard var metadata = csvMetadata else { return }
        metadata.duplicateResolution = resolution
        csvMetadata = metadata
    }

    package func setMatchScope(_ scope: ImportMatchScope) {
        guard var metadata = csvMetadata else { return }
        metadata.matchScope = scope
        csvMetadata = metadata
    }

    package func selectDeck(_ id: DeckID) {
        guard var metadata = csvMetadata else { return }
        metadata.deck = .deck(id)
        csvMetadata = metadata
    }

    package func selectDeckColumn(_ column: Int) {
        guard var metadata = csvMetadata else { return }
        metadata.deck = .column(max(0, column))
        csvMetadata = metadata
    }

    package func setNewDeckName(_ name: String) {
        guard var metadata = csvMetadata else { return }
        metadata.deck = .newDeck(name)
        csvMetadata = metadata
    }

    package func setGlobalTags(_ value: String) {
        globalTagsDraft = value
        guard var metadata = csvMetadata else { return }
        metadata.globalTags = value.split(whereSeparator: \.isWhitespace).map(String.init)
        csvMetadata = metadata
    }

    package func setUpdatedTags(_ value: String) {
        updatedTagsDraft = value
        guard var metadata = csvMetadata else { return }
        metadata.updatedTags = value.split(whereSeparator: \.isWhitespace).map(String.init)
        csvMetadata = metadata
    }

    package var globalTagsText: String { globalTagsDraft }

    package var updatedTagsText: String { updatedTagsDraft }

    package var suggestedDeckName: String {
        URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
    }

    // MARK: - Preflight

    private func loadReview(for format: AnkiImportFormat, path: String) async throws {
        switch format {
        case .deckPackage, .zippedPackage:
            async let inspection = importExportService.inspectPackage(path)
            async let presets = importExportService.ankiPackageImportPresets()
            packageInspection = try await inspection
            packageOptions = try await presets
        case .collectionPackage:
            packageInspection = try await importExportService.inspectPackage(path)
        case .text:
            try await loadTextReview(path: path)
        case .ankiJSON:
            let data = try Data(contentsOf: stagedURL ?? sourceURL, options: .mappedIfSafe)
            jsonSummary = try AnkiJSONImportSummary(inspect: data)
        case .mnemosyne:
            let deckService = decksService
            async let inspection = importExportService.inspectMnemosyne(path)
            async let allDecks = Task.detached(priority: .userInitiated) {
                try deckService.fetchAll()
            }.value
            mnemosyneInspection = try await inspection
            let fetchedDecks = try await allDecks
            decks = fetchedDecks.filter { !$0.isFiltered }.sortedByName
            mnemosyneDeckName = decks.first?.name ?? suggestedDeckName
        }
    }

    private func loadTextReview(path: String) async throws {
        let deckService = decksService
        let notetypeService = notetypesService
        async let metadata = importExportService.csvImportMetadata(
            path,
            CSVImportMetadataQuery()
        )
        async let allDecks = Task.detached(priority: .userInitiated) {
            try deckService.fetchAll()
        }.value
        async let allNotetypes = Task.detached(priority: .userInitiated) {
            try notetypeService.getNotetypeNames()
        }.value
        var loadedMetadata = try await metadata
        let fetchedDecks = try await allDecks
        let fetchedNotetypeNames = try await allNotetypes
        decks = fetchedDecks.filter { !$0.isFiltered }.sortedByName
        notetypes = fetchedNotetypeNames
            .map { NotetypeNameId(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if case .global(let mapped) = loadedMetadata.notetype,
           mapped.id.rawValue == 0,
           let first = notetypes.first {
            loadedMetadata.notetype = .global(.init(id: first.id, fieldColumns: mapped.fieldColumns))
        }
        if case .newDeck(let name) = loadedMetadata.deck,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadedMetadata.deck = .newDeck(suggestedDeckName)
        }
        csvMetadata = loadedMetadata
        globalTagsDraft = loadedMetadata.globalTags.joined(separator: " ")
        updatedTagsDraft = loadedMetadata.updatedTags.joined(separator: " ")
        try await loadSelectedNotetypeFields(from: loadedMetadata)
    }

    private func refreshCSVMetadata(
        preservingTags: Bool,
        tags: [String],
        updatedTags: [String]
    ) async throws {
        guard let metadata = csvMetadata else { return }
        let notetypeID: NotetypeID?
        if case .global(let mapped) = metadata.notetype {
            notetypeID = mapped.id
        } else {
            notetypeID = nil
        }
        let deckID: DeckID?
        if case .deck(let id) = metadata.deck {
            deckID = id
        } else {
            deckID = nil
        }
        var refreshed = try await importExportService.csvImportMetadata(
            stagedURL?.path ?? sourceURL.path,
            CSVImportMetadataQuery(
                delimiter: metadata.delimiter,
                notetypeID: notetypeID,
                deckID: deckID,
                isHTML: metadata.isHTML
            )
        )
        refreshed.forceDelimiter = metadata.forceDelimiter
        refreshed.forceIsHTML = metadata.forceIsHTML
        if preservingTags {
            refreshed.globalTags = tags
            refreshed.updatedTags = updatedTags
        }
        csvMetadata = refreshed
        globalTagsDraft = refreshed.globalTags.joined(separator: " ")
        updatedTagsDraft = refreshed.updatedTags.joined(separator: " ")
        try await loadSelectedNotetypeFields(from: refreshed)
    }

    private func loadSelectedNotetypeFields(from metadata: CSVImportMetadata) async throws {
        guard case .global(let mapped) = metadata.notetype else {
            notetypeFields = []
            return
        }
        let notetypeService = notetypesService
        let notetype = try await Task.detached(priority: .userInitiated) {
            try notetypeService.getNotetype(mapped.id)
        }.value
        notetypeFields = notetype.fieldNames
    }

    // MARK: - Import

    private func executeImport(format: AnkiImportFormat, path: String) async throws -> ImportLogSummary {
        switch format {
        case .deckPackage, .zippedPackage:
            return try await importExportService.importAnkiPackageWithOptions(path, packageOptions)
        case .collectionPackage:
            guard let stagedURL else { throw ImportReviewFailure.missingStagedFile }
            try await replaceCollection(stagedURL)
            let noteCount = packageInspection?.noteCount ?? 0
            return ImportLogSummary(
                foundNotes: noteCount,
                newCount: noteCount,
                updatedCount: 0,
                duplicateCount: 0
            )
        case .text:
            guard let metadata = csvMetadata else { throw ImportReviewFailure.missingReview }
            return try await importExportService.importCSV(path, metadata)
        case .ankiJSON:
            return try await importExportService.importJSONFile(path)
        case .mnemosyne:
            return try await importExportService.importMnemosyne(path, mnemosyneDeckName)
        }
    }

    // MARK: - Staging and presentation

    private static func stage(sourceURL: URL) async throws -> (url: URL, directory: URL, byteCount: Int64) {
        try await Task.detached(priority: .userInitiated) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AnkiImport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                return (destination, directory, Int64(values.fileSize ?? 0))
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private static func message(for error: any Error, format: AnkiImportFormat?) -> String {
        if let failure = error as? ImportReviewFailure {
            return failure.errorDescription
        }
        let raw = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        let lowered = raw.lowercased()
        if format == .deckPackage || format == .collectionPackage || format == .zippedPackage {
            if lowered.contains("zip") || lowered.contains("archive") || lowered.contains("invalid file") {
                return "This file doesn’t appear to be a valid Anki package. It may be damaged or created by a newer version of Anki."
            }
        }
        if format == .mnemosyne,
           lowered.contains("mnemosyne") || lowered.contains("global_variables") {
            return "This database is not a readable Mnemosyne collection. Choose a Mnemosyne SQL 1, 2, or 3 database."
        }
        if format == .text,
           lowered.contains("csv") || lowered.contains("unicode") || lowered.contains("utf-8") {
            return "Ijuka couldn’t read this text file. Save it as UTF-8 CSV, TSV, or tab-separated text and try again."
        }
        return raw
    }
}

package enum ImportReviewFailure: Error, Equatable {
    case unsupported(String)
    case missingStagedFile
    case missingReview
    case invalidJSON(String)

    package var errorDescription: String {
        switch self {
        case .unsupported(let extensionName):
            let suffix = extensionName.isEmpty ? "file" : ".\(extensionName) file"
            return "Ijuka can’t import this \(suffix). Choose an Anki package, collection backup, ZIP package, CSV, TSV, TXT, Anki JSON, or Mnemosyne database."
        case .missingStagedFile:
            return "The selected file is no longer available. Choose it again and retry."
        case .missingReview:
            return "The import details could not be prepared. Choose the file again and retry."
        case .invalidJSON(let detail):
            return "This Anki JSON file is invalid. \(detail)"
        }
    }
}

extension AnkiJSONImportSummary {
    package init(inspect data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportReviewFailure.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ImportReviewFailure.invalidJSON("The top level must be a JSON object.")
        }
        guard let notes = dictionary["notes"] as? [[String: Any]] else {
            throw ImportReviewFailure.invalidJSON("The “notes” value must be an array.")
        }
        let notetypes = dictionary["notetypes"] as? [[String: Any]] ?? []
        let globalTags = dictionary["global_tags"] as? [String] ?? []
        let cards = notes.reduce(0) { partial, note in
            partial + ((note["cards"] as? [Any])?.count ?? 0)
        }
        let defaultDeck: String?
        if let name = dictionary["default_deck"] as? String {
            defaultDeck = name
        } else if let id = dictionary["default_deck"] as? NSNumber {
            defaultDeck = id.stringValue
        } else {
            defaultDeck = nil
        }
        self.init(
            noteCount: notes.count,
            cardCount: cards,
            notetypeCount: notetypes.count,
            globalTagCount: globalTags.count,
            defaultDeck: defaultDeck
        )
    }
}
