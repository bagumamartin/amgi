import Foundation
import Testing
import AnkiKit
@testable import AnkiBackend
@testable import AnkiProtoBridge

/// Exercises the new import RPCs against the real Rust engine rather than
/// only checking protobuf bytes. This catches service/method drift and keeps
/// the Swift review flow honest about what the vendored Anki build accepts.
@Suite("Import/export engine probes", .serialized)
struct ImportExportEngineProbesTests {
    @Test @MainActor
    func probesAllBuiltInImportFamilies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-import-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = try AnkiBackend(preferredLangs: ["en"])
        let mediaFolder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        try backend.openCollection(
            collectionPath: root.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: mediaFolder.path,
            mediaDbPath: root.appendingPathComponent("media.db").path
        )
        defer { try? backend.closeCollection() }

        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = fixtureRoot
            .appendingPathComponent("anki-upstream/pylib/tests/support/media.apkg")
        let mnemosyneURL = fixtureRoot
            .appendingPathComponent("anki-upstream/pylib/tests/support/mnemo.db")

        let package = try await backend.invoke(.inspectAnkiPackage(path: packageURL.path))
        #expect(package.noteCount > 0)
        #expect(package.mediaCount > 0)

        let mnemosyne = try await backend.invoke(.inspectMnemosyne(path: mnemosyneURL.path))
        #expect(mnemosyne.noteCount == 5)
        #expect(mnemosyne.cardCount == 7)

        let csvURL = root.appendingPathComponent("cards.csv")
        try "hello,world\n".write(to: csvURL, atomically: true, encoding: .utf8)
        let metadata = try await backend.invoke(.csvImportMetadata(
            path: csvURL.path,
            query: CSVImportMetadataQuery()
        ))
        #expect(!metadata.preview.isEmpty)
        let csvResult = try await backend.invoke(.importCSV(path: csvURL.path, metadata: metadata))
        #expect(csvResult.newCount > 0)

        let jsonURL = root.appendingPathComponent("empty.anki-json")
        try #"{"notes":[]}"#.write(to: jsonURL, atomically: true, encoding: .utf8)
        let jsonResult = try await backend.invoke(.importJSONFile(path: jsonURL.path))
        #expect(jsonResult.foundNotes == 0)

        let mnemosyneResult = try await backend.invoke(.importMnemosyne(
            path: mnemosyneURL.path,
            deckName: "Default"
        ))
        #expect(mnemosyneResult.importedCount > 0)

        let notesTextURL = root.appendingPathComponent("notes.txt")
        let exportedNotes = try await backend.invoke(.exportNoteText(
            scope: .collection,
            outPath: notesTextURL.path,
            options: NoteTextExportOptions(includeTags: true, includeDeck: true)
        ))
        #expect(exportedNotes > 0)
        #expect(try Data(contentsOf: notesTextURL).isEmpty == false)

        let cardsTextURL = root.appendingPathComponent("cards.txt")
        let exportedCards = try await backend.invoke(.exportCardText(
            scope: .collection,
            outPath: cardsTextURL.path,
            options: CardTextExportOptions()
        ))
        #expect(exportedCards > 0)
        #expect(try Data(contentsOf: cardsTextURL).isEmpty == false)

        let packageURLForExport = root.appendingPathComponent("collection.apkg")
        let exportedPackageNotes = try await backend.invoke(.exportAnkiPackage(
            scope: .collection,
            outPath: packageURLForExport.path,
            options: AnkiPackageExportOptions(includeScheduling: true, includeMedia: false)
        ))
        #expect(exportedPackageNotes > 0)
        let exportedPackage = try await backend.invoke(.inspectAnkiPackage(path: packageURLForExport.path))
        #expect(exportedPackage.noteCount > 0)

        let backupURL = root.appendingPathComponent("roundtrip.colpkg")
        try await backend.invoke(.exportCollectionPackage(
            outPath: backupURL.path,
            includeMedia: false
        ))
        // The upstream export RPC takes the collection out of the backend;
        // it is already closed here, so only the restore and reopen remain.
        try await backend.invoke(.importCollectionPackage(
            collectionPath: root.appendingPathComponent("collection.anki2").path,
            packagePath: backupURL.path,
            mediaFolderPath: mediaFolder.path,
            mediaDatabasePath: root.appendingPathComponent("media.db").path
        ))
        try backend.openCollection(
            collectionPath: root.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: mediaFolder.path,
            mediaDbPath: root.appendingPathComponent("media.db").path
        )
    }
}
