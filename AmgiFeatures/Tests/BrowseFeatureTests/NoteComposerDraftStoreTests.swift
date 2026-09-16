import Foundation
import Testing
@testable import BrowseFeature

@Suite("Note composer drafts", .serialized)
struct NoteComposerDraftStoreTests {
    init() {
        NoteComposerDraftStore.resetForTests()
    }

    @Test func savesAndListsMultipleAddDrafts() {
        let first = NoteComposerDraft(
            deckID: 1,
            notetypeID: 10,
            fieldNames: ["Front"],
            fieldValues: ["<b>alpha</b>"],
            tags: "",
            noteID: nil
        )
        let second = NoteComposerDraft(
            deckID: 2,
            notetypeID: 10,
            fieldNames: ["Front"],
            fieldValues: ["beta"],
            tags: "",
            noteID: nil
        )
        NoteComposerDraftStore.saveAdd(first)
        NoteComposerDraftStore.saveAdd(second)

        let all = NoteComposerDraftStore.allAddDrafts()
        #expect(all.map(\.id).contains(first.id))
        #expect(all.map(\.id).contains(second.id))
        #expect(NoteComposerDraftStore.addDrafts(inDeckIDs: [1]).map(\.id) == [first.id])
    }

    @Test func deletesAddDraft() {
        let draft = NoteComposerDraft(
            deckID: 1,
            notetypeID: 10,
            fieldNames: ["Front"],
            fieldValues: ["gone"],
            tags: "",
            noteID: nil
        )
        NoteComposerDraftStore.saveAdd(draft)
        NoteComposerDraftStore.deleteAdd(id: draft.id)
        #expect(NoteComposerDraftStore.allAddDrafts().isEmpty)
    }

    @Test func editDraftRoundTripsAndDeletes() {
        var draft = NoteComposerDraft(
            deckID: 7,
            notetypeID: 10,
            fieldNames: ["Front"],
            fieldValues: ["edited"],
            tags: "tag",
            noteID: 99
        )
        NoteComposerDraftStore.saveEdit(draft)
        let loaded = NoteComposerDraftStore.loadEdit(noteID: 99)
        #expect(loaded?.fieldValues == ["edited"])
        #expect(loaded?.deckID == 7)

        draft.fieldValues = ["edited again"]
        NoteComposerDraftStore.saveEdit(draft)
        let again = NoteComposerDraftStore.loadEdit(noteID: 99)
        #expect(again?.id == loaded?.id)
        #expect(again?.fieldValues == ["edited again"])

        NoteComposerDraftStore.deleteEdit(noteID: 99)
        #expect(NoteComposerDraftStore.loadEdit(noteID: 99) == nil)
        #expect(NoteComposerDraftStore.allEditDrafts().count == 0)
    }

    @Test func editDraftNeverDuplicatesPerNote() {
        let first = NoteComposerDraft(
            id: UUID(),
            deckID: 1,
            notetypeID: 10,
            fieldNames: ["Front"],
            fieldValues: ["one"],
            tags: "",
            noteID: 42
        )
        let second = NoteComposerDraft(
            id: UUID(),
            deckID: 1,
            notetypeID: 10,
            fieldNames: ["Front"],
            fieldValues: ["two"],
            tags: "",
            noteID: 42
        )
        NoteComposerDraftStore.saveEdit(first)
        NoteComposerDraftStore.saveEdit(second)
        let edits = NoteComposerDraftStore.allEditDrafts().filter { $0.noteID == 42 }
        #expect(edits.count == 1)
        #expect(edits.first?.fieldValues == ["two"])
        #expect(edits.first?.id == first.id)
    }

    @Test func previewStripsHTML() {
        #expect(NoteComposerDraft.plainPreview("<div>Hello&nbsp;<b>world</b></div>") == "Hello world")
        #expect(
            NoteComposerDraft(
                deckID: nil,
                notetypeID: nil,
                fieldNames: ["Front"],
                fieldValues: ["<img src=\"x.jpg\">"],
                tags: "",
                noteID: nil
            ).preview == "Empty draft"
        )
    }

    @Test func migratesLegacySingleAddDraft() {
        let legacy = NoteComposerDraft(
            deckID: 3,
            notetypeID: 1,
            fieldNames: ["Front"],
            fieldValues: ["legacy"],
            tags: "",
            noteID: nil
        )
        let data = try! JSONEncoder().encode(legacy)
        NoteComposerDraftStore.writeLegacyAddForTests(data)
        let loaded = NoteComposerDraftStore.allAddDrafts()
        #expect(loaded.contains(where: { $0.fieldValues == ["legacy"] }))
        #expect(loaded.contains(where: { $0.deckID == 3 }))
    }
}
