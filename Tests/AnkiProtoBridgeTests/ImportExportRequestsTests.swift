import Testing
import Foundation
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
private import SwiftProtobuf

@Suite struct ImportExportRequestsTests {
    // MARK: - importAnkiPackage

    @Test func importAnkiPackage_dispatches_to_importExport_service() {
        let envelope: Request<ImportLogSummary> = .importAnkiPackage(path: "/tmp/x.apkg")
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.importAnkiPackage)
    }

    @Test func importAnkiPackage_encodes_path() throws {
        let envelope: Request<ImportLogSummary> = .importAnkiPackage(path: "/tmp/deck.apkg")
        let proto = try Anki_ImportExport_ImportAnkiPackageRequest(serializedBytes: envelope.body)
        #expect(proto.packagePath == "/tmp/deck.apkg")
    }

    @Test func importAnkiPackage_decodes_log_counts() throws {
        var note = Anki_ImportExport_ImportResponse.Note()
        note.fields = ["a", "b"]
        var log = Anki_ImportExport_ImportResponse.Log()
        log.new = [note, note, note]
        log.updated = [note]
        log.duplicate = [note, note]
        var resp = Anki_ImportExport_ImportResponse()
        resp.log = log
        let bytes = try resp.serializedData()

        let envelope: Request<ImportLogSummary> = .importAnkiPackage(path: "/x")
        let result = try envelope.decode(bytes)

        #expect(result.newCount == 3)
        #expect(result.updatedCount == 1)
        #expect(result.duplicateCount == 2)
    }

    @Test func packageImport_encodes_reviewed_options() throws {
        let options = AnkiPackageImportOptions(
            mergeNotetypes: true,
            updateNotes: .always,
            updateNotetypes: .never,
            withScheduling: true,
            withDeckConfigs: true
        )
        let envelope: Request<ImportLogSummary> = .importAnkiPackage(
            path: "/tmp/deck.apkg",
            options: options
        )
        let proto = try Anki_ImportExport_ImportAnkiPackageRequest(serializedBytes: envelope.body)
        #expect(proto.packagePath == "/tmp/deck.apkg")
        #expect(proto.options.mergeNotetypes)
        #expect(proto.options.updateNotes == .always)
        #expect(proto.options.updateNotetypes == .never)
        #expect(proto.options.withScheduling)
        #expect(proto.options.withDeckConfigs)
    }

    @Test func importLog_decodes_every_diagnostic_bucket() throws {
        let note = Anki_ImportExport_ImportResponse.Note()
        var log = Anki_ImportExport_ImportResponse.Log()
        log.foundNotes = 10
        log.conflicting = [note]
        log.firstFieldMatch = [note, note]
        log.missingNotetype = [note]
        log.missingDeck = [note]
        log.emptyFirstField = [note]
        var response = Anki_ImportExport_ImportResponse()
        response.log = log

        let envelope: Request<ImportLogSummary> = .importAnkiPackage(
            path: "/x",
            options: AnkiPackageImportOptions()
        )
        let summary = try envelope.decode(response.serializedData())
        #expect(summary.foundNotes == 10)
        #expect(summary.conflictingCount == 1)
        #expect(summary.firstFieldMatchCount == 2)
        #expect(summary.missingNotetypeCount == 1)
        #expect(summary.missingDeckCount == 1)
        #expect(summary.emptyFirstFieldCount == 1)
    }

    // MARK: - Delimited text

    @Test func csvMetadataRequest_encodes_optional_constraints() throws {
        let envelope: Request<CSVImportMetadata> = .csvImportMetadata(
            path: "/tmp/cards.tsv",
            query: CSVImportMetadataQuery(
                delimiter: .semicolon,
                notetypeID: NotetypeID(7),
                deckID: DeckID(9),
                isHTML: true
            )
        )
        #expect(envelope.methodId == ImportExportMethod.getCSVMetadata)
        let proto = try Anki_ImportExport_CsvMetadataRequest(serializedBytes: envelope.body)
        #expect(proto.path == "/tmp/cards.tsv")
        #expect(proto.delimiter == .semicolon)
        #expect(proto.notetypeID == 7)
        #expect(proto.deckID == 9)
        #expect(proto.isHtml)
    }

    @Test func importCSV_encodes_complete_mapping() throws {
        let metadata = CSVImportMetadata(
            delimiter: .pipe,
            isHTML: true,
            globalTags: ["imported"],
            updatedTags: ["changed"],
            columnLabels: ["Front", "Back", "Tags"],
            deck: .deck(DeckID(12)),
            notetype: .global(.init(id: NotetypeID(4), fieldColumns: [2, 1, 0])),
            tagsColumn: 3,
            forceDelimiter: true,
            forceIsHTML: true,
            preview: [["A", "B", "tag"]],
            guidColumn: 0,
            duplicateResolution: .preserve,
            matchScope: .notetypeAndDeck
        )
        let envelope: Request<ImportLogSummary> = .importCSV(path: "/tmp/cards.csv", metadata: metadata)
        let proto = try Anki_ImportExport_ImportCsvRequest(serializedBytes: envelope.body)
        #expect(proto.path == "/tmp/cards.csv")
        #expect(proto.metadata.delimiter == .pipe)
        #expect(proto.metadata.deckID == 12)
        #expect(proto.metadata.globalNotetype.id == 4)
        #expect(proto.metadata.globalNotetype.fieldColumns == [2, 1, 0])
        #expect(proto.metadata.tagsColumn == 3)
        #expect(proto.metadata.dupeResolution == .preserve)
        #expect(proto.metadata.matchScope == .notetypeAndDeck)
    }

    // MARK: - Collection package and aux inspection

    @Test func importCollectionPackage_encodes_all_paths() throws {
        let envelope: Request<Void> = .importCollectionPackage(
            collectionPath: "/profile/collection.anki2",
            packagePath: "/incoming.colpkg",
            mediaFolderPath: "/profile/media",
            mediaDatabasePath: "/profile/media.db"
        )
        #expect(envelope.methodId == ImportExportMethod.importCollectionPackage)
        let proto = try Anki_ImportExport_ImportCollectionPackageRequest(serializedBytes: envelope.body)
        #expect(proto.colPath == "/profile/collection.anki2")
        #expect(proto.backupPath == "/incoming.colpkg")
        #expect(proto.mediaFolder == "/profile/media")
        #expect(proto.mediaDb == "/profile/media.db")
    }

    @Test func aux_error_preserves_raw_inspection_message() {
        let error = BackendError(errorBytes: Data("file is not a valid ZIP-based Anki package".utf8))
        #expect(error.kind == .invalidInput)
        #expect(error.message.contains("valid ZIP-based"))
    }

    @Test func packageInspection_dispatches_to_aux_service_and_decodes() throws {
        let envelope: Request<ImportPackageInspection> = .inspectAnkiPackage(path: "/tmp/deck.apkg")
        #expect(envelope.serviceId == ServiceID.aux)
        #expect(envelope.methodId == AuxMethod.inspectAnkiPackage)
        let json = Data("""
            {"format_version":3,"note_count":12,"card_count":24,"notetype_count":2,\
            "review_count":5,"deck_names":["Language"],"media_count":3,"archive_entry_count":6}
            """.utf8)
        let inspection = try envelope.decode(json)
        #expect(inspection.formatVersion == 3)
        #expect(inspection.noteCount == 12)
        #expect(inspection.deckNames == ["Language"])
    }

    // MARK: - exportCollectionPackage

    @Test func exportCollectionPackage_dispatches_and_sets_fields() throws {
        let envelope: Request<Void> = .exportCollectionPackage(outPath: "/tmp/c.colpkg", includeMedia: true)
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.exportCollectionPackage)
        let proto = try Anki_ImportExport_ExportCollectionPackageRequest(serializedBytes: envelope.body)
        #expect(proto.outPath == "/tmp/c.colpkg")
        #expect(proto.includeMedia)
        #expect(!proto.legacy)
    }

    @Test func exportCollectionPackage_encodes_legacy_option() throws {
        let envelope: Request<Void> = .exportCollectionPackage(
            outPath: "/tmp/c.colpkg", includeMedia: false, legacy: true
        )
        let proto = try Anki_ImportExport_ExportCollectionPackageRequest(serializedBytes: envelope.body)
        #expect(!proto.includeMedia)
        #expect(proto.legacy)
    }

    @Test func scopeDrivenPackageExport_encodes_note_and_card_limits() throws {
        let notes: Request<UInt32> = .exportAnkiPackage(
            scope: .notes([NoteID(7), NoteID(9)], label: "Selected notes"),
            outPath: "/tmp/notes.apkg",
            options: AnkiPackageExportOptions()
        )
        let noteProto = try Anki_ImportExport_ExportAnkiPackageRequest(serializedBytes: notes.body)
        #expect(noteProto.limit.noteIds.noteIds == [7, 9])

        let cards: Request<UInt32> = .exportAnkiPackage(
            scope: .cards([CardID(4), CardID(8)], label: "Selected cards"),
            outPath: "/tmp/cards.apkg",
            options: AnkiPackageExportOptions()
        )
        let cardProto = try Anki_ImportExport_ExportAnkiPackageRequest(serializedBytes: cards.body)
        #expect(cardProto.limit.cardIds.cids == [4, 8])
    }

    @Test func textExports_encode_scope_and_format_options() throws {
        let notes: Request<UInt32> = .exportNoteText(
            scope: .notes([NoteID(12)], label: "Selected notes"),
            outPath: "/tmp/notes.txt",
            options: NoteTextExportOptions(
                includeHTML: false,
                includeTags: true,
                includeDeck: true,
                includeNotetype: true,
                includeGUID: true
            )
        )
        let noteProto = try Anki_ImportExport_ExportNoteCsvRequest(serializedBytes: notes.body)
        #expect(notes.methodId == ImportExportMethod.exportNoteCSV)
        #expect(!noteProto.withHtml)
        #expect(noteProto.withTags)
        #expect(noteProto.withDeck)
        #expect(noteProto.withNotetype)
        #expect(noteProto.withGuid)
        #expect(noteProto.limit.noteIds.noteIds == [12])

        let cards: Request<UInt32> = .exportCardText(
            scope: .cards([CardID(22)], label: "Selected cards"),
            outPath: "/tmp/cards.txt",
            options: CardTextExportOptions(includeHTML: false)
        )
        let cardProto = try Anki_ImportExport_ExportCardCsvRequest(serializedBytes: cards.body)
        #expect(cards.methodId == ImportExportMethod.exportCardCSV)
        #expect(!cardProto.withHtml)
        #expect(cardProto.limit.cardIds.cids == [22])
    }

    @Test func csvNamedAliasesEncodeTheSameTextExport() throws {
        let notes: Request<UInt32> = .exportNoteCsv(
            scope: .notes([NoteID(3)], label: "Selected notes"),
            outPath: "/tmp/notes.txt",
            options: NoteTextExportOptions()
        )
        let proto = try Anki_ImportExport_ExportNoteCsvRequest(serializedBytes: notes.body)
        #expect(notes.methodId == ImportExportMethod.exportNoteCSV)
        #expect(proto.limit.noteIds.noteIds == [3])

        let cards: Request<UInt32> = .exportCardCsv(
            scope: .cards([CardID(5)], label: "Selected cards"),
            outPath: "/tmp/cards.txt",
            options: CardTextExportOptions()
        )
        #expect(cards.methodId == ImportExportMethod.exportCardCSV)
    }

    // MARK: - exportAnkiPackage

    @Test func exportAnkiPackage_dispatches_to_exportAnkiPackage() {
        let envelope: Request<UInt32> = .exportAnkiPackage(
            deckId: DeckID(42), outPath: "/tmp/d.apkg",
            withScheduling: true, withDeckConfigs: false, withMedia: true, legacy: false
        )
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.exportAnkiPackage)
    }

    @Test func exportAnkiPackage_encodes_options_and_limit() throws {
        let envelope: Request<UInt32> = .exportAnkiPackage(
            deckId: DeckID(99), outPath: "/tmp/d.apkg",
            withScheduling: true, withDeckConfigs: true, withMedia: false, legacy: true
        )
        let proto = try Anki_ImportExport_ExportAnkiPackageRequest(serializedBytes: envelope.body)
        #expect(proto.outPath == "/tmp/d.apkg")
        #expect(proto.options.withScheduling)
        #expect(proto.options.withDeckConfigs)
        #expect(!proto.options.withMedia)
        #expect(proto.options.legacy)
        #expect(proto.limit.deckID == 99)
    }

    @Test func exportAnkiPackage_decodes_count() throws {
        var resp = Anki_Generic_UInt32()
        resp.val = 1234
        let bytes = try resp.serializedData()

        let envelope: Request<UInt32> = .exportAnkiPackage(
            deckId: DeckID(1), outPath: "/x",
            withScheduling: false, withDeckConfigs: false, withMedia: false, legacy: false
        )
        #expect(try envelope.decode(bytes) == 1234)
    }
}
