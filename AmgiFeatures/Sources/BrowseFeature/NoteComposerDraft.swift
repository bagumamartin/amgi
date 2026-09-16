import Foundation
import AmgiAppCore

struct NoteComposerDraft: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var updatedAt: Date
    var deckID: Int64?
    var notetypeID: Int64?
    var fieldNames: [String]
    var fieldValues: [String]
    var tags: String
    var noteID: Int64?

    init(
        id: UUID = UUID(),
        updatedAt: Date = Date(),
        deckID: Int64?,
        notetypeID: Int64?,
        fieldNames: [String],
        fieldValues: [String],
        tags: String,
        noteID: Int64?
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.deckID = deckID
        self.notetypeID = notetypeID
        self.fieldNames = fieldNames
        self.fieldValues = fieldValues
        self.tags = tags
        self.noteID = noteID
    }

    var isEdit: Bool { noteID != nil }

    enum CodingKeys: String, CodingKey {
        case id, updatedAt, deckID, notetypeID, fieldNames, fieldValues, tags, noteID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        deckID = try container.decodeIfPresent(Int64.self, forKey: .deckID)
        notetypeID = try container.decodeIfPresent(Int64.self, forKey: .notetypeID)
        fieldNames = try container.decodeIfPresent([String].self, forKey: .fieldNames) ?? []
        fieldValues = try container.decodeIfPresent([String].self, forKey: .fieldValues) ?? []
        tags = try container.decodeIfPresent(String.self, forKey: .tags) ?? ""
        noteID = try container.decodeIfPresent(Int64.self, forKey: .noteID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deckID, forKey: .deckID)
        try container.encodeIfPresent(notetypeID, forKey: .notetypeID)
        try container.encode(fieldNames, forKey: .fieldNames)
        try container.encode(fieldValues, forKey: .fieldValues)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(noteID, forKey: .noteID)
    }

    var preview: String {
        for value in fieldValues {
            let plain = Self.plainPreview(value)
            if !plain.isEmpty { return plain }
        }
        return "Empty draft"
    }

    static func plainPreview(_ html: String) -> String {
        var text = html
        while let start = text.firstIndex(of: "<") {
            if let end = text[start...].firstIndex(of: ">") {
                text.removeSubrange(start...end)
            } else {
                break
            }
        }
        let unescaped = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\u{200B}", with: "")
        return unescaped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NoteComposerDraftStore {
    private static let addsKey = "amgi.noteDraft.adds"
    private static let legacyAddKey = "amgi.noteDraft.add"
    private static let editPrefix = "amgi.noteDraft.edit."

    private static var defaults: UserDefaults { AppGroup.defaults }

    static func allAddDrafts() -> [NoteComposerDraft] {
        migrateLegacyAddIfNeeded()
        return loadAdds().sorted { $0.updatedAt > $1.updatedAt }
    }

    static func allEditDrafts() -> [NoteComposerDraft] {
        migrateLegacyAddIfNeeded()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(editPrefix) }
        return keys.compactMap { load($0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func addDrafts(inDeckIDs deckIDs: Set<Int64>?) -> [NoteComposerDraft] {
        let drafts = allAddDrafts()
        guard let deckIDs else { return drafts }
        return drafts.filter { draft in
            guard let id = draft.deckID else { return false }
            return deckIDs.contains(id)
        }
    }

    static func editDrafts(inDeckIDs deckIDs: Set<Int64>?) -> [NoteComposerDraft] {
        let drafts = allEditDrafts()
        guard let deckIDs else { return drafts }
        return drafts.filter { draft in
            guard let id = draft.deckID else { return false }
            return deckIDs.contains(id)
        }
    }

    static func loadAdd() -> NoteComposerDraft? { allAddDrafts().first }

    static func loadEdit(noteID: Int64) -> NoteComposerDraft? { load(editKey(noteID)) }

    static func saveAdd(_ draft: NoteComposerDraft) {
        var next = draft
        next.noteID = nil
        if next.updatedAt.timeIntervalSince1970 == 0 { next.updatedAt = Date() }
        var adds = loadAdds()
        if let index = adds.firstIndex(where: { $0.id == next.id }) {
            adds[index] = next
        } else {
            adds.append(next)
        }
        persistAdds(adds)
    }

    static func saveEdit(_ draft: NoteComposerDraft) {
        guard let noteID = draft.noteID else { return }
        var next = draft
        if let existing = load(editKey(noteID)) {
            next.id = existing.id
        }
        next.updatedAt = Date()
        save(next, key: editKey(noteID))
    }

    static func deleteAdd(id: UUID) {
        persistAdds(loadAdds().filter { $0.id != id })
    }

    static func deleteEdit(noteID: Int64) {
        defaults.removeObject(forKey: editKey(noteID))
    }

    static func clearAdd() {
        if let first = loadAdds().first {
            deleteAdd(id: first.id)
        }
        defaults.removeObject(forKey: legacyAddKey)
    }

    static func clearEdit(noteID: Int64) { deleteEdit(noteID: noteID) }

    static func delete(_ draft: NoteComposerDraft) {
        if let noteID = draft.noteID {
            deleteEdit(noteID: noteID)
        } else {
            deleteAdd(id: draft.id)
        }
    }

    static func resetForTests() {
        defaults.removeObject(forKey: addsKey)
        defaults.removeObject(forKey: legacyAddKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(editPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static func writeLegacyAddForTests(_ data: Data) {
        defaults.set(data, forKey: legacyAddKey)
    }

    private static func editKey(_ noteID: Int64) -> String { editPrefix + String(noteID) }

    private static func loadAdds() -> [NoteComposerDraft] {
        guard let data = defaults.data(forKey: addsKey) else { return [] }
        return (try? JSONDecoder().decode([NoteComposerDraft].self, from: data)) ?? []
    }

    private static func persistAdds(_ drafts: [NoteComposerDraft]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        defaults.set(data, forKey: addsKey)
    }

    private static func migrateLegacyAddIfNeeded() {
        guard let data = defaults.data(forKey: legacyAddKey) else { return }
        if let draft = try? JSONDecoder().decode(NoteComposerDraft.self, from: data) {
            saveAdd(draft)
        }
        defaults.removeObject(forKey: legacyAddKey)
    }

    private static func load(_ key: String) -> NoteComposerDraft? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NoteComposerDraft.self, from: data)
    }

    private static func save(_ draft: NoteComposerDraft, key: String) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key)
    }
}