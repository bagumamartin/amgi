package import Foundation
package import SwiftUI
import AmgiAppCore
import AnkiServices
package import AnkiKit
import Dependencies
package import Observation
package import UniformTypeIdentifiers

package enum ExportReviewPhase: Equatable, Sendable {
    case preparing
    case review
    case exporting
    case readyToSave
    case completed
    case failed
}

package struct ExportedFile: Identifiable, Equatable, Sendable {
    package let url: URL
    package let defaultFilename: String
    package let byteCount: Int64
    package let itemCount: Int?
    package var savedURL: URL?

    package var id: URL { url }
    package var shareURL: URL { savedURL ?? url }
}

package enum ExportReviewFailure: Error, Equatable {
    case noSelection
    case noFormat
    case missingCollection
    case emptyOutput
    case invalidPackage
    case profileChanged
    case saveFailed(String)
    case exportFailed(String)

    package var errorDescription: String {
        switch self {
        case .noSelection:
            return "Choose a deck or selection to export."
        case .noFormat:
            return "Choose an export format to continue."
        case .missingCollection:
            return "The collection could not be found. Open a collection and try again."
        case .emptyOutput:
            return "Ijuka finished the export but did not create a usable file. Try again."
        case .invalidPackage:
            return "The exported package could not be verified. It was not saved; try again."
        case .profileChanged:
            return "The active profile changed while the export was being prepared. No file was saved."
        case .saveFailed(let detail):
            return detail
        case .exportFailed(let detail):
            return detail
        }
    }
}

/// The single state machine behind every export entry point in the app.
@MainActor
@Observable
package final class ExportReviewModel {
    package private(set) var phase: ExportReviewPhase = .preparing
    package private(set) var scope: ExportScope
    package private(set) var availableScopes: [ExportScope] = []
    package private(set) var decks: [DeckInfo] = []
    @ObservationIgnored private var topLevelDecks: [DeckInfo] = []
    package private(set) var failureMessage: String?
    package private(set) var saveFailureMessage: String?
    package private(set) var output: ExportedFile?
    package private(set) var fileExporterRequestID: UUID?
    package private(set) var didNotifyCompletion = false

    package var format: ExportFormat
    package var packageOptions = AnkiPackageExportOptions()
    package var noteTextOptions = NoteTextExportOptions()
    package var cardTextOptions = CardTextExportOptions()

    @ObservationIgnored private let request: ExportRequest
    @ObservationIgnored private let profileID: String
    @ObservationIgnored private let beforeExport: @MainActor @Sendable () async throws -> Void
    @ObservationIgnored private let afterExport: @MainActor @Sendable () -> Void
    @ObservationIgnored private let onCollectionFailure: @MainActor @Sendable (String, String) -> Void
    @ObservationIgnored private let onComplete: @MainActor @Sendable () -> Void
    @ObservationIgnored private var stagingDirectory: URL?
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private var exportInFlight = false
    @ObservationIgnored private var fileExporterPresented = false
    @ObservationIgnored private var cleanupRequested = false
    @ObservationIgnored private var recoveryPending = false
    @ObservationIgnored private var didNotifyCollectionFailure = false
    @ObservationIgnored private var didFinishExportLifecycle = false

    @ObservationIgnored @Dependency(\.importExportService) private var importExport
    @ObservationIgnored @Dependency(\.decksService) private var decksService

    package init(
        request: ExportRequest,
        beforeExport: @escaping @MainActor @Sendable () async throws -> Void = {},
        afterExport: @escaping @MainActor @Sendable () -> Void = {},
        onCollectionFailure: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
        onComplete: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.request = request
        self.scope = request.scope
        self.profileID = AccountStore.shared.selectedID
        self.beforeExport = beforeExport
        self.afterExport = afterExport
        self.onCollectionFailure = onCollectionFailure
        self.onComplete = onComplete
        let formats = Self.formats(for: request.scope, allowed: request.allowedFormats)
        self.format = formats.first ?? .deckPackage
    }

    package var allowsScopeChange: Bool { request.allowsScopeChange }
    package var sourceName: String? { request.sourceName }
    package var expectedItemCount: Int? {
        if let itemCount = request.itemCount { return itemCount }
        switch scope {
        case .collection:
            let total = topLevelDecks.reduce(0) { $0 + $1.counts.total }
            return total > 0 ? total : nil
        case .deck(let id, _):
            return decks.first(where: { $0.id == id })?.counts.total
        case .notes(let ids, _):
            return ids.count
        case .cards(let ids, _):
            return ids.count
        }
    }
    package var isCollectionScope: Bool { scope == .collection }

    package var availableFormats: [ExportFormat] {
        Self.formats(for: scope, allowed: request.allowedFormats)
    }

    package var canExport: Bool {
        phase == .review && !availableFormats.isEmpty && !scopeIsEmpty
    }

    package var isBusy: Bool { phase == .preparing || phase == .exporting }

    package var navigationTitle: String {
        switch phase {
        case .preparing: "Export"
        case .review: "Export"
        case .exporting: "Exporting"
        case .readyToSave: "Save Export"
        case .completed: "Export Complete"
        case .failed: "Can’t Export"
        }
    }

    package var primaryActionTitle: String {
        switch format {
        case .collectionPackage: "Create Collection Package"
        case .deckPackage: "Create Anki Package"
        case .noteText: "Export Notes"
        case .cardText: "Export Cards"
        }
    }

    package var fileDocument: ExportedFileDocument? {
        guard let output else { return nil }
        return try? ExportedFileDocument(
            sourceURL: output.url,
            contentType: format.contentType
        )
    }

    package var contentType: UTType { format.contentType }
    package var defaultFilename: String { output?.defaultFilename ?? suggestedFilename }
    package var shareURL: URL? { output?.shareURL }
    package var savedURL: URL? { output?.savedURL }
    package var outputByteCount: Int64? { output?.byteCount }
    package var outputItemCount: Int? { output?.itemCount }

    package func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        phase = .preparing
        failureMessage = nil

        do {
            if request.allowsScopeChange {
                let service = decksService
                let tree = try await Task.detached(priority: .userInitiated) {
                    try service.fetchTree()
                }.value
                topLevelDecks = tree
                    .filter { !$0.isFiltered }
                    .map {
                        DeckInfo(
                            id: $0.id,
                            name: $0.fullName,
                            counts: $0.counts,
                            isFiltered: $0.isFiltered
                        )
                    }
                decks = Self.flatten(tree).filter { !$0.isFiltered }
                availableScopes = [.collection] + decks.map { .deck($0.id, name: $0.name) }
            } else {
                availableScopes = [request.scope]
            }
            normalizeFormat()
            phase = .review
        } catch {
            phase = .failed
            failureMessage = Self.message(for: error)
        }
    }

    package func selectScope(_ newScope: ExportScope) {
        guard allowsScopeChange, phase == .review else { return }
        scope = newScope
        normalizeFormat()
        failureMessage = nil
    }

    package func selectFormat(_ newFormat: ExportFormat) {
        guard availableFormats.contains(newFormat) else { return }
        format = newFormat
        failureMessage = nil
    }

    package func setPackageScheduling(_ value: Bool) {
        packageOptions.includeScheduling = value
    }

    package func setPackageDeckConfigurations(_ value: Bool) {
        packageOptions.includeDeckConfigurations = value
    }

    package func setPackageMedia(_ value: Bool) {
        packageOptions.includeMedia = value
    }

    package func setPackageLegacy(_ value: Bool) {
        packageOptions.legacy = value
    }

    package func setNoteHTML(_ value: Bool) {
        noteTextOptions.includeHTML = value
    }

    package func setNoteTags(_ value: Bool) {
        noteTextOptions.includeTags = value
    }

    package func setNoteDeck(_ value: Bool) {
        noteTextOptions.includeDeck = value
    }

    package func setNoteType(_ value: Bool) {
        noteTextOptions.includeNotetype = value
    }

    package func setNoteGUID(_ value: Bool) {
        noteTextOptions.includeGUID = value
    }

    package func setCardHTML(_ value: Bool) {
        cardTextOptions.includeHTML = value
    }

    package func exportNow() async {
        guard phase == .review, canExport else { return }
        var lifecycleStarted = false
        defer {
            if lifecycleStarted && !recoveryPending {
                finishExportLifecycle()
            }
        }
        guard AccountStore.shared.selectedID == profileID else {
            phase = .failed
            failureMessage = ExportReviewFailure.profileChanged.errorDescription
            return
        }
        cleanupRequested = true
        performCleanupIfPossible()
        phase = .exporting
        exportInFlight = true
        cleanupRequested = false
        defer {
            exportInFlight = false
            performCleanupIfPossible()
        }
        guard !Task.isCancelled else { return }
        do {
            try await beforeExport()
            lifecycleStarted = true
        } catch {
            phase = .failed
            failureMessage = "Export cancelled."
            cleanupRequested = true
            return
        }
        guard !Task.isCancelled, !cleanupRequested else { return }
        guard AccountStore.shared.selectedID == profileID else {
            phase = .failed
            failureMessage = ExportReviewFailure.profileChanged.errorDescription
            return
        }
        failureMessage = nil
        saveFailureMessage = nil
        output = nil
        fileExporterRequestID = nil

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AmgiExport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stagingDirectory = directory

            let destination = directory.appendingPathComponent(suggestedFilename)
            let service = importExport
            let scope = self.scope
            let format = self.format
            let packageOptions = self.packageOptions
            let noteOptions = self.noteTextOptions
            let cardOptions = self.cardTextOptions
            let path = destination.path

            let itemCount: Int?
            switch format {
            case .collectionPackage:
                let profileDirectory = AccountStore.profileDirectory(
                    for: profileID
                )
                let collectionPath = profileDirectory.appendingPathComponent("collection.anki2").path
                let mediaFolderPath = profileDirectory.appendingPathComponent("media", isDirectory: true).path
                let mediaDatabasePath = profileDirectory.appendingPathComponent("media.db").path
                guard FileManager.default.fileExists(atPath: collectionPath) else {
                    throw ExportReviewFailure.missingCollection
                }
                try await Task.detached(priority: .userInitiated) {
                    try service.exportCollectionPackageAndReopenWithLegacy(
                        path,
                        packageOptions.includeMedia,
                        packageOptions.legacy,
                        collectionPath,
                        mediaFolderPath,
                        mediaDatabasePath
                    )
                }.value
                // The engine writes the colpkg, so the reader libraries have to
                // be appended afterwards. Without this a backup restores the
                // notes but not the books they point at (reading positions
                // travel separately through iCloud). The extension is unchanged
                // and the extra entries live under an `ijuka/` prefix, so Anki
                // still imports this normally.
                _ = try ReaderBackupBundle.addReaderLibrary(
                    toPackageAt: destination,
                    epubRoot: profileDirectory.appendingPathComponent("EPUB", isDirectory: true),
                    pdfRoot: profileDirectory.appendingPathComponent("PDF", isDirectory: true)
                )
                itemCount = nil
            case .deckPackage:
                itemCount = Int(try await Task.detached(priority: .userInitiated) {
                    try service.exportPackage(
                        scope: scope,
                        outPath: path,
                        options: packageOptions
                    )
                }.value)
            case .noteText:
                itemCount = Int(try await Task.detached(priority: .userInitiated) {
                    try service.exportNoteText(
                        scope: scope,
                        outPath: path,
                        options: noteOptions
                    )
                }.value)
            case .cardText:
                itemCount = Int(try await Task.detached(priority: .userInitiated) {
                    try service.exportCardText(
                        scope: scope,
                        outPath: path,
                        options: cardOptions
                    )
                }.value)
            }

            guard AccountStore.shared.selectedID == profileID else {
                throw ExportReviewFailure.profileChanged
            }
            guard !cleanupRequested, !Task.isCancelled else { return }
            let byteCount = try Self.validateOutput(at: destination)
            if format == .collectionPackage || format == .deckPackage {
                // Package inspection catches truncated archives before the
                // native Save panel is allowed to publish them.
                _ = try await importExport.inspectPackage(path)
            }

            output = ExportedFile(
                url: destination,
                defaultFilename: suggestedFilename,
                byteCount: byteCount,
                itemCount: itemCount,
                savedURL: nil
            )
            phase = .readyToSave
            fileExporterRequestID = UUID()
            notifyCompletionIfNeeded()
        } catch {
            if error is CancellationError {
                phase = .failed
                failureMessage = "Export cancelled."
                cleanupRequested = true
                return
            }
            if let reopenError = error as? CollectionExportReopenError {
                recoveryPending = true
                let message = reopenError.errorDescription ?? "The collection could not be reopened."
                if let recoveredOutput = try? Self.persistRecoveryOutput(
                    at: reopenError.outputPath,
                    defaultFilename: suggestedFilename,
                    profileID: profileID
                ) {
                    // The archive is valid even though reopening the collection
                    // failed. Persist it outside the temporary staging directory
                    // and let the user save it before the root enters recovery.
                    output = recoveredOutput
                    phase = .readyToSave
                    saveFailureMessage = "The collection package was created, but Ijuka could not reopen the collection. Save this recovery package before closing the app."
                    fileExporterRequestID = UUID()
                    return
                }
                phase = .failed
                failureMessage = message
                cleanupRequested = true
                notifyCollectionFailureIfNeeded(message)
                return
            }
            phase = .failed
            failureMessage = Self.message(for: error)
            cleanupRequested = true
        }
    }

    package func handleSaveResult(_ result: Result<URL, any Error>) {
        fileExporterPresented = false
        switch result {
        case .success(let url):
            let recoveryMessage = saveFailureMessage
            output?.savedURL = url
            if recoveryPending,
               let recoveryURL = output?.url,
               recoveryURL != url {
                try? FileManager.default.removeItem(at: recoveryURL)
            }
            saveFailureMessage = nil
            phase = .completed
            NotificationCenter.default.post(name: .amgiExportDidSave, object: url)
            notifyCollectionFailureIfNeeded(
                recoveryMessage ?? "The collection package was created, but Ijuka could not reopen the collection."
            )
        case .failure(let error):
            // The engine export is still valid. Keep the staged file so the
            // user can retry Save without running the export again.
            if (error as NSError).code == NSUserCancelledError {
                phase = .readyToSave
            } else {
                saveFailureMessage = Self.message(for: error)
                phase = .readyToSave
            }
        }
        performCleanupIfPossible()
    }

    package func setFileExporterPresented(_ presented: Bool) {
        fileExporterPresented = presented
        if !presented { performCleanupIfPossible() }
    }

    package func retry() async {
        cleanupRequested = true
        performCleanupIfPossible()
        hasPrepared = false
        recoveryPending = false
        didNotifyCollectionFailure = false
        didFinishExportLifecycle = false
        phase = .preparing
        await prepare()
    }

    package func cleanup() {
        cleanupRequested = true
        if recoveryPending && !fileExporterPresented {
            notifyCollectionFailureIfNeeded(
                saveFailureMessage ?? "The collection package was created, but Ijuka could not reopen the collection."
            )
        }
        performCleanupIfPossible()
    }

    // MARK: - Derived state

    private var scopeIsEmpty: Bool {
        switch scope {
        case .collection, .deck: false
        case .notes(let ids, _): ids.isEmpty
        case .cards(let ids, _): ids.isEmpty
        }
    }

    private var suggestedFilename: String {
        let base: String
        switch scope {
        case .collection:
            base = "Collection"
        case .deck(_, let name):
            base = name
        case .notes(_, let label):
            base = label
        case .cards(_, let label):
            base = label
        }
        let safe = Self.sanitizeFilename(base)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(safe)-\(formatter.string(from: .now)).\(format.fileExtension)"
    }

    private func normalizeFormat() {
        let formats = availableFormats
        guard !formats.isEmpty else {
            failureMessage = ExportReviewFailure.noFormat.errorDescription
            return
        }
        if !formats.contains(format) {
            format = formats[0]
        }
    }

    private func notifyCollectionFailureIfNeeded(_ message: String) {
        guard recoveryPending, !didNotifyCollectionFailure else { return }
        didNotifyCollectionFailure = true
        onCollectionFailure(message, profileID)
        // Recovery may leave the collection closed until the root retries.
        // Keep the lifecycle barrier until that failure has been surfaced.
        finishExportLifecycle()
    }

    private func finishExportLifecycle() {
        guard !didFinishExportLifecycle else { return }
        didFinishExportLifecycle = true
        afterExport()
    }

    private func performCleanupIfPossible() {
        guard cleanupRequested, !exportInFlight, !fileExporterPresented else { return }
        if recoveryPending {
            notifyCollectionFailureIfNeeded(
                saveFailureMessage ?? "The collection package was created, but Ijuka could not reopen the collection."
            )
        }
        cleanupStagedOutput()
        cleanupRequested = false
    }

    private func notifyCompletionIfNeeded() {
        guard !didNotifyCompletion else { return }
        didNotifyCompletion = true
        onComplete()
    }

    // MARK: - Output staging

    private func cleanupStagedOutput() {
        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        stagingDirectory = nil
    }

    private static func validateOutput(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw ExportReviewFailure.emptyOutput
        }
        return Int64(size)
    }

    private static func persistRecoveryOutput(
        at path: String,
        defaultFilename: String,
        profileID: String
    ) throws -> ExportedFile {
        let source = URL(fileURLWithPath: path)
        let byteCount = try validateOutput(at: source)
        let recoveryDirectory = AccountStore.profileDirectory(
            for: profileID
        ).appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let recoveryURL = recoveryDirectory.appendingPathComponent(
            "Amgi-Export-Recovery-\(UUID().uuidString).\(source.pathExtension)"
        )
        try FileManager.default.copyItem(at: source, to: recoveryURL)
        return ExportedFile(
            url: recoveryURL,
            defaultFilename: defaultFilename,
            byteCount: byteCount,
            itemCount: nil,
            savedURL: nil
        )
    }

    private static func message(for error: any Error) -> String {
        if let failure = error as? ExportReviewFailure {
            return failure.errorDescription
        }
        let raw = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        return raw
    }

    private static func formats(
        for scope: ExportScope,
        allowed: [ExportFormat]
    ) -> [ExportFormat] {
        allowed.filter { format in
            format != .collectionPackage || scope == .collection
        }
    }

    private static func flatten(_ nodes: [DeckTreeNode]) -> [DeckInfo] {
        nodes.flatMap { node in
            [DeckInfo(id: node.id, name: node.fullName, counts: node.counts, isFiltered: node.isFiltered)]
                + flatten(node.children)
        }
    }

    private static func sanitizeFilename(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value.components(separatedBy: disallowed).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Ijuka Export" : String(cleaned.prefix(80))
    }
}

package struct ExportedFileDocument: FileDocument {
    package let sourceURL: URL

    package init(sourceURL: URL, contentType: UTType) throws {
        _ = contentType
        self.sourceURL = sourceURL
    }

    package init(configuration: ReadConfiguration) throws {
        // This document is write-only. The export coordinator already owns
        // the staged URL; opening arbitrary documents here would eagerly load
        // potentially large packages into memory.
        throw CocoaError(.fileReadUnknown)
    }

    package static var readableContentTypes: [UTType] {
        [
            .data,
            .plainText,
            .zip,
            ExportFormat.deckPackage.contentType,
            ExportFormat.collectionPackage.contentType,
        ]
    }

    package static var writableContentTypes: [UTType] {
        readableContentTypes
    }

    package func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .withoutMapping)
    }
}

extension ExportFormat {
    package static let deckPackageContentType = UTType(
        exportedAs: "com.bagumamartin.ijuka.anki-package",
        conformingTo: .zip
    )
    package static let collectionPackageContentType = UTType(
        exportedAs: "com.bagumamartin.ijuka.anki-collection-package",
        conformingTo: .zip
    )

    package var contentType: UTType {
        switch self {
        case .deckPackage:
            Self.deckPackageContentType
        case .collectionPackage:
            Self.collectionPackageContentType
        case .noteText, .cardText:
            .plainText
        }
    }

    package var systemImage: String {
        switch self {
        case .collectionPackage: "externaldrive.fill.badge.timemachine"
        case .deckPackage: "rectangle.stack.fill"
        case .noteText: "note.text"
        case .cardText: "rectangle.on.rectangle.angled"
        }
    }

    package var detail: String {
        switch self {
        case .collectionPackage:
            "A complete collection backup, including media and settings."
        case .deckPackage:
            "An Anki package for sharing, merging, or importing into another collection."
        case .noteText:
            "UTF-8 text with one note per row, separated by tabs."
        case .cardText:
            "UTF-8 text with one card per row, separated by tabs."
        }
    }
}
