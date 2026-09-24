import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AmgiAppShared

@Suite("Anki import format detection")
struct ImportFormatTests {
    @Test(
        arguments: [
            ("deck.apkg", AnkiImportFormat.deckPackage),
            ("collection.apkg", AnkiImportFormat.collectionPackage),
            ("backup-2026-09-23.apkg", AnkiImportFormat.collectionPackage),
            ("Photos.colpkg", AnkiImportFormat.collectionPackage),
            ("deck.zip", AnkiImportFormat.zippedPackage),
            ("cards.csv", AnkiImportFormat.text),
            ("cards.tsv", AnkiImportFormat.text),
            ("cards.txt", AnkiImportFormat.text),
            ("collection.anki-json", AnkiImportFormat.ankiJSON),
            ("mnemosyne.db", AnkiImportFormat.mnemosyne),
        ]
    )
    func detectsDesktopAnkiImportFamilies(name: String, expected: AnkiImportFormat) {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        #expect(AnkiImportFormat(url: url) == expected)
    }

    @Test func rejectsRawCollectionDatabases() {
        #expect(AnkiImportFormat(url: URL(fileURLWithPath: "/tmp/collection.anki2")) == nil)
        #expect(AnkiImportFormat(url: URL(fileURLWithPath: "/tmp/collection.anki21")) == nil)
    }

    @Test func supportedTypesIncludeEveryRegisteredExtension() {
        let identifiers = Set(AnkiImportFormat.supportedContentTypes.map(\.identifier))
        for extensionName in AnkiImportFormat.supportedExtensions {
            #expect(identifiers.contains(UTType(filenameExtension: extensionName)?.identifier ?? "missing-\(extensionName)"))
        }
    }
}

@Suite("Anki JSON import preview")
struct AnkiJSONImportSummaryTests {
    @Test func summarizesNotesCardsNoteTypesTagsAndDeck() throws {
        let data = Data("""
            {
              "default_deck": "Japanese",
              "global_tags": ["imported", "verified"],
              "notetypes": [{"name": "Basic"}],
              "notes": [
                {"fields": ["A", "B"], "cards": [{}, {}]},
                {"fields": ["C", "D"], "cards": [{}]}
              ]
            }
            """.utf8)
        let summary = try AnkiJSONImportSummary(inspect: data)
        #expect(summary.noteCount == 2)
        #expect(summary.cardCount == 3)
        #expect(summary.notetypeCount == 1)
        #expect(summary.globalTagCount == 2)
        #expect(summary.defaultDeck == "Japanese")
    }

    @Test func rejectsNonObjectAndMissingNotes() {
        #expect(throws: ImportReviewFailure.self) {
            _ = try AnkiJSONImportSummary(inspect: Data("[]".utf8))
        }
        #expect(throws: ImportReviewFailure.self) {
            _ = try AnkiJSONImportSummary(inspect: Data("{}".utf8))
        }
    }
}
