import Foundation
import AmgiAppCore

struct NoteComposerDraft: Codable, Equatable, Sendable {
    var deckID: Int64?
    var notetypeID: Int64?
    var fieldNames: [String]
    var fieldValues: [String]
    var tags: String
    var noteID: Int64?
}

enum NoteComposerDraftStore {
    private static let addKey = "amgi.noteDraft.add"
    private static func editKey(_ noteID: Int64) -> String { "amgi.noteDraft.edit.\(noteID)" }

    static func loadAdd() -> NoteComposerDraft? { load(addKey) }

    static func loadEdit(noteID: Int64) -> NoteComposerDraft? { load(editKey(noteID)) }

    static func saveAdd(_ draft: NoteComposerDraft) { save(draft, key: addKey) }

    static func saveEdit(_ draft: NoteComposerDraft) {
        guard let noteID = draft.noteID else { return }
        save(draft, key: editKey(noteID))
    }

    static func clearAdd() { AppGroup.defaults.removeObject(forKey: addKey) }

    static func clearEdit(noteID: Int64) { AppGroup.defaults.removeObject(forKey: editKey(noteID)) }

    private static func load(_ key: String) -> NoteComposerDraft? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NoteComposerDraft.self, from: data)
    }

    private static func save(_ draft: NoteComposerDraft, key: String) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }
}
