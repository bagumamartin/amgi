import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AmgiAppShared
import AnkiKit
import AnkiServices
import Dependencies

@Suite("Export review model")
struct ExportReviewModelTests {
    @Test @MainActor
    func fixedSelectionDefaultsToAnkiPackageAndKeepsAllFormats() {
        let model = ExportReviewModel(
            request: ExportRequest(
                scope: .cards([CardID(4), CardID(8)], label: "Selected cards")
            )
        )

        #expect(model.format == .deckPackage)
        #expect(model.availableFormats == [.deckPackage, .noteText, .cardText])
        #expect(model.navigationTitle == "Export")
    }

    @Test @MainActor
    func collectionPackageIsOnlyOfferedForCollectionScope() async {
        let model = ExportReviewModel(
            request: ExportRequest(
                scope: .deck(DeckID(3), name: "Japanese"),
                allowedFormats: [.collectionPackage, .deckPackage, .noteText]
            )
        )
        await model.prepare()

        #expect(model.phase == .review)
        #expect(model.format == .deckPackage)
        #expect(model.availableFormats == [.deckPackage, .noteText])
    }

    @Test @MainActor
    func selectionCanChangeBetweenFormatsWithoutLosingScope() {
        let model = ExportReviewModel(
            request: ExportRequest(scope: .notes([NoteID(9)], label: "Review queue"))
        )
        model.selectFormat(.noteText)
        #expect(model.format == .noteText)
        #expect(model.scope == .notes([NoteID(9)], label: "Review queue"))
    }

    @Test @MainActor
    func noteExportStagesAValidFileBeforeOfferingSaveAs() async throws {
        var service = ImportExportService.testValue
        service.exportNoteText = { _, path, _ in
            try Data("front\tback\n".utf8).write(
                to: URL(fileURLWithPath: path),
                options: .atomic
            )
            return 1
        }

        await withDependencies {
            $0.importExportService = service
        } operation: {
            let model = ExportReviewModel(
                request: ExportRequest(
                    scope: .notes([NoteID(1)], label: "Selected notes"),
                    allowedFormats: [.noteText]
                )
            )
            await model.prepare()
            await model.exportNow()

            #expect(model.phase == .readyToSave)
            #expect(model.outputItemCount == 1)
            #expect(model.outputByteCount == 11)
            #expect(model.fileDocument?.sourceURL == model.output?.url)

            model.handleSaveResult(.failure(CancellationError()))
            #expect(model.phase == .readyToSave)
            model.cleanup()
        }
    }

    @Test
    func exportedDocumentReferencesTheStagedFileWithoutLoadingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiExportDocumentTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("front\tback\n".utf8).write(to: file)

        let document = try ExportedFileDocument(sourceURL: file, contentType: .plainText)
        #expect(document.sourceURL == file)
    }

    @Test
    func formatContentTypesMatchRegisteredAnkiTypes() {
        #expect(ExportFormat.deckPackage.contentType.identifier == "com.bagumamartin.ijuka.anki-package")
        #expect(ExportFormat.collectionPackage.contentType.identifier == "com.bagumamartin.ijuka.anki-collection-package")
        #expect(ExportFormat.noteText.contentType == .plainText)
    }
}
