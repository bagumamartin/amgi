import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
import Dependencies
import Foundation
import Testing
@testable import AssistantFeature

@Suite("Assistant reviewed note corrections", .serialized) @MainActor
struct AssistantNoteCorrectionTests {
    @Test("saving changes only approved fields and preserves current tags and rich text")
    func savesReviewedFields() async throws {
        try await withNote { backend, before, names, activation in
            var tagged = before
            tagged.tags = " added-while-reviewing "
            try await backend.invoke(.updateNote(tagged))
            var draft = correction(before, names)
            draft.fields.append(.init(id: 1, name: names[1], before: "<b>back</b>", after: "declined", included: false))

            try await AssistantToolbox.saveCorrection(draft, expected: before, fieldNames: names, activation: activation)

            let saved = try await backend.invoke(.getNote(id: before.id))
            #expect(saved.flds == "reviewed front\u{1f}<b>back</b>")
            #expect(saved.tags.contains("added-while-reviewing"))
        }
    }

    @Test("an edit to any field while approval is open rejects the whole correction")
    func rejectsConcurrentFieldEdit() async throws {
        try await withNote { backend, before, names, activation in
            var edited = before
            edited.flds = "front\u{1f}concurrent answer"
            try await backend.invoke(.updateNote(edited))

            await #expect(throws: (any Error).self) {
                try await AssistantToolbox.saveCorrection(correction(before, names), expected: before, fieldNames: names, activation: activation)
            }
            let unchanged = try await backend.invoke(.getNote(id: before.id))
            #expect(unchanged.flds == edited.flds)
        }
    }

    @Test("a renamed field invalidates approval even when the field text is unchanged")
    func rejectsChangedSchema() async throws {
        try await withNote { backend, before, names, activation in
            var type = try await backend.invoke(.notetype(for: before.mid))
            type.fields[0].name = "Question"
            for index in type.templates.indices {
                type.templates[index].config.qFormat = type.templates[index].config.qFormat.replacingOccurrences(of: "{{Front}}", with: "{{Question}}")
                type.templates[index].config.aFormat = type.templates[index].config.aFormat.replacingOccurrences(of: "{{Front}}", with: "{{Question}}")
            }
            try await backend.invoke(.updateNotetype(type))
            let renamed = try await backend.invoke(.getNote(id: before.id))
            #expect(renamed.flds == before.flds)

            await #expect(throws: (any Error).self) {
                try await AssistantToolbox.saveCorrection(correction(before, names), expected: before, fieldNames: names, activation: activation)
            }
            let unchanged = try await backend.invoke(.getNote(id: before.id))
            #expect(unchanged.flds == before.flds)
        }
    }

    @Test("approval from another collection activation cannot write")
    func rejectsChangedActivation() async throws {
        try await withNote { backend, before, names, activation in
            // An activation mismatch must reject before touching any note.
            await #expect(throws: AssistantError.self) {
                try await AssistantToolbox.saveCorrection(correction(before, names), expected: before, fieldNames: names, activation: UUID())
            }
            #expect(backend.collectionActivationID == activation)
            let unchanged = try await backend.invoke(.getNote(id: before.id))
            #expect(unchanged.flds == before.flds)
        }
    }

    @Test("a deleted note is not recreated by an outstanding approval")
    func rejectsDeletedNote() async throws {
        try await withNote { backend, before, names, activation in
            try await backend.invoke(.removeNotes(noteIds: [before.id]))
            await #expect(throws: (any Error).self) {
                try await AssistantToolbox.saveCorrection(correction(before, names), expected: before, fieldNames: names, activation: activation)
            }
            let remaining = try await backend.invoke(.searchNoteIds(query: ""))
            #expect(remaining.isEmpty)
        }
    }

    private func correction(_ before: NoteRecord, _ names: [String]) -> NoteFixDraft {
        NoteFixDraft(noteID: before.id.rawValue, fields: [
            .init(id: 0, name: names[0], before: "front", after: "reviewed front")
        ])
    }

    private func withNote(
        _ operation: @MainActor (AnkiBackend, NoteRecord, [String], UUID) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-correction-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try AnkiBackend()
        try backend.openCollection(
            collectionPath: directory.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: directory.appendingPathComponent("media").path,
            mediaDbPath: directory.appendingPathComponent("media.db").path
        )
        defer { try? backend.closeCollection() }
        let type = try #require(try await backend.invoke(.notetypeNames).first { $0.name == "Basic" })
        let names = try await backend.invoke(.notetype(for: type.id)).fields.map(\.name)
        var template = try await backend.invoke(.newNote(notetypeId: type.id))
        template.fields = ["front", "<b>back</b>"]
        try await backend.invoke(.addNote(template: template, deckId: DeckID(1)))
        let id = try #require(try await backend.invoke(.searchNoteIds(query: "")).first)
        let before = try await backend.invoke(.getNote(id: id))
        let activation = try #require(backend.collectionActivationID)
        try await withDependencies {
            $0.ankiBackend = backend
            $0.notesService = .liveValue
        } operation: {
            try await operation(backend, before, names, activation)
        }
    }
}
