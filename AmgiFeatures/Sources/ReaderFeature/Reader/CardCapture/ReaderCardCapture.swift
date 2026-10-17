import AmgiReader
import AmgiAppShared
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation
import OSLog

/// Where one book's cards go: a deck and a two-sided note type.
///
/// Chosen once per book and then never asked again — the same "set it on
/// first use, change it from the card" model Photos uses for an import
/// destination. A book with no choice yet inherits the last one made in any
/// book, so a reader working through a series sets it exactly once.
struct ReaderCardDestination: Codable, Hashable, Sendable {
    var deckID: Int64
    var notetypeID: Int64
}

/// The note-writing half of reading capture, shared by every entry point:
/// the dictionary popup's one-tap ⊕, Make Card on a selection, and the draft
/// stack. One place decides the destination, builds the fields, and writes the
/// note, so the three paths cannot drift into three slightly different cards.
@Observable
@MainActor
final class ReaderCardCapture {
    struct Deck: Hashable, Identifiable {
        let id: Int64
        let name: String
    }

    struct Notetype: Hashable, Identifiable {
        let id: Int64
        let name: String
        let fieldNames: [String]
    }

    /// Decks and note types a reading card can go to. Cloze and one-field
    /// note types are left out: a card here always has a front and a back.
    private(set) var decks: [Deck] = []
    private(set) var notetypes: [Notetype] = []
    private(set) var isLoaded = false

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService
    @ObservationIgnored @Dependency(\.notesService) private var notesService
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    private static let log = Logger(subsystem: "Amgi", category: "ReaderCardCapture")

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await reload()
    }

    func reload() async {
        let allDecks = (try? await deckClient.fetchAll()) ?? []
        decks = allDecks
            .filter { !$0.isFiltered }
            .map { Deck(id: $0.id.rawValue, name: $0.name) }
        do {
            let service = notetypesService
            notetypes = try await backendOffload {
                try service.getNotetypeNames().compactMap { entry in
                    let info = try service.getNotetype(entry.id)
                    guard info.kind != .cloze, info.fieldNames.count >= 2 else { return nil }
                    return Notetype(id: info.id.rawValue, name: info.name, fieldNames: info.fieldNames)
                }
            }
        } catch {
            Self.log.error("Loading note types failed: \(error.localizedDescription)")
        }
        isLoaded = true
    }

    // MARK: - Destination

    /// The book's destination, falling back to the last one used anywhere,
    /// then to a "Basic"-named note type and the first deck. Always validated
    /// against the live collection, so a deleted deck never strands a card.
    func destination(forBook bookID: String?) async -> ReaderCardDestination? {
        await loadIfNeeded()
        let candidates = [bookID.map(Self.bookKey), Self.lastKey].compactMap { $0 }
        for key in candidates {
            if let stored = Self.stored(key), isValid(stored) { return stored }
        }
        guard let notetype = notetypes.first(where: { $0.name.localizedCaseInsensitiveCompare("Basic") == .orderedSame })
                ?? notetypes.first,
              let deck = decks.first(where: { $0.id != 1 }) ?? decks.first
        else { return nil }
        return ReaderCardDestination(deckID: deck.id, notetypeID: notetype.id)
    }

    func setDestination(_ destination: ReaderCardDestination, forBook bookID: String?) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        if let bookID { UserDefaults.standard.set(data, forKey: Self.bookKey(bookID)) }
        UserDefaults.standard.set(data, forKey: Self.lastKey)
    }

    func deckName(_ id: Int64) -> String? {
        decks.first { $0.id == id }?.name
    }

    func notetype(_ id: Int64) -> Notetype? {
        notetypes.first { $0.id == id }
    }

    private func isValid(_ destination: ReaderCardDestination) -> Bool {
        decks.contains { $0.id == destination.deckID }
            && notetypes.contains { $0.id == destination.notetypeID }
    }

    private static func bookKey(_ bookID: String) -> String { "reader_card_destination_\(bookID)" }
    private static let lastKey = "reader_card_destination_last"

    private static func stored(_ key: String) -> ReaderCardDestination? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ReaderCardDestination.self, from: data)
    }

    // MARK: - Writing

    enum CaptureError: LocalizedError {
        case noDestination
        var errorDescription: String? {
            "Choose a deck and note type for cards from this book."
        }
    }

    /// Writes a two-sided card: `front` into the note type's first field,
    /// `back` into its second. Plain text in, HTML out. Pictures — media
    /// file names already in the collection — follow each side's text.
    func addCard(
        front: String,
        back: String,
        frontImages: [String] = [],
        backImages: [String] = [],
        tags: [String],
        destination: ReaderCardDestination
    ) async throws -> NoteID {
        try await write(
            notetypeID: destination.notetypeID,
            deckID: destination.deckID,
            tags: tags
        ) { fieldNames in
            var fields = Array(repeating: "", count: fieldNames.count)
            if fields.indices.contains(0) { fields[0] = Self.field(front, images: frontImages) }
            if fields.indices.contains(1) { fields[1] = Self.field(back, images: backImages) }
            return fields
        }
    }

    /// Adds to a card already in the collection: `front` after its first
    /// field, `back` after its second, each on a new line. Returns the
    /// fields as they were, for undo.
    func appendToCard(_ noteID: NoteID, front: String, back: String) async throws -> String {
        let notes = notesService
        let previous = try await backendOffload { () throws -> String in
            var note = try notes.getNote(noteID)
            let before = note.flds
            var fields = note.flds.components(separatedBy: "\u{1f}")
            for (index, addition) in [front, back].enumerated() where fields.indices.contains(index) && !addition.isEmpty {
                fields[index] = fields[index].isEmpty ? addition : fields[index] + "<br>" + addition
            }
            note.flds = fields.joined(separator: "\u{1f}")
            try notes.saveNote(note)
            return before
        }
        collectionStore.apply(CollectionChanges(card: true, note: true))
        return previous
    }

    /// Puts a card's fields back as they were — the undo for an addition.
    func restoreFields(_ noteID: NoteID, to flds: String) async {
        let notes = notesService
        do {
            try await backendOffload {
                var note = try notes.getNote(noteID)
                note.flds = flds
                try notes.saveNote(note)
            }
            collectionStore.apply(CollectionChanges(card: true, note: true))
        } catch {
            Self.log.error("Undoing an addition failed: \(error.localizedDescription)")
        }
    }

    /// A card's front and back as plain text, for the dock's "adding to".
    func sides(of noteID: NoteID) async -> (front: String, back: String)? {
        let notes = notesService
        guard let note = try? await backendOffload({ try notes.getNote(noteID) }) else { return nil }
        let fields = note.flds.components(separatedBy: "\u{1f}").map(Self.plainText)
        return (fields.first ?? "", fields.count > 1 ? fields[1] : "")
    }

    /// A field's HTML as one line of text: tags dropped, entities decoded.
    nonisolated static func plainText(_ html: String) -> String {
        let withoutTags = html
            .replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<img[^>]*>", with: " [picture] ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        return ReaderSourceAnchor.normalize(decoded)
    }

    /// Writes a note from a by-field-name draft — the user's configured
    /// lookup template. Values are already the user's mapping; they are not
    /// re-escaped, since a template may map rich dictionary output.
    func addMapped(
        _ draft: AddNoteDraft,
        fallbackDeckID: Int64
    ) async throws -> NoteID {
        guard let notetypeID = draft.notetypeID else { throw CaptureError.noDestination }
        return try await write(
            notetypeID: notetypeID,
            deckID: draft.deckID ?? fallbackDeckID,
            tags: draft.tags
        ) { fieldNames in
            fieldNames.map { draft.fieldValues[$0] ?? "" }
        }
    }

    /// Undo for a capture. Deleting is safe because the note was created
    /// seconds ago by this same gesture and has no review history yet.
    func remove(_ noteID: NoteID) async {
        let notes = notesService
        do {
            try await backendOffload { try notes.deleteNote(noteID) }
            collectionStore.apply(CollectionChanges(card: true, note: true, studyQueues: true))
        } catch {
            Self.log.error("Undoing capture failed: \(error.localizedDescription)")
        }
    }

    /// Whether a note already holds `term` in `field`, searched collection
    /// wide. Drives the ✓ "already a card" state before the user taps.
    func hasNote(field: String, matching term: String) async -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty, !trimmed.isEmpty else { return false }
        let query = "\"\(Self.searchEscaped(field)):\(Self.searchEscaped(trimmed))\""
        let notes = notesService
        let ids = (try? await backendOffload { try notes.searchNoteIds(query) }) ?? []
        return !ids.isEmpty
    }

    private func write(
        notetypeID: Int64,
        deckID: Int64,
        tags: [String],
        fields makeFields: @escaping @Sendable ([String]) -> [String]
    ) async throws -> NoteID {
        let notes = notesService
        let types = notetypesService
        let creation = try await backendOffload {
            let id = NotetypeID(rawValue: notetypeID)
            let info = try types.getNotetype(id)
            var template = try notes.newNote(id)
            template.fields = makeFields(info.fieldNames)
            template.tags = tags
            return try notes.createNote(template, DeckID(rawValue: deckID))
        }
        collectionStore.apply(creation.changes)
        return creation.noteID
    }

    // MARK: - Formatting

    /// Escapes plain reading text for a field and keeps its paragraphs.
    nonisolated static func html(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// A field: the side's text, then its pictures, each on its own line.
    nonisolated static func field(_ text: String, images: [String]) -> String {
        let pictures = images.map { "<img src=\"\(attributeEscaped($0))\">" }
        return ([html(text)].filter { !$0.isEmpty } + pictures).joined(separator: "<br>")
    }

    nonisolated static func attributeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// Escapes Anki search syntax so a term like `C++` or `don't_care`
    /// searches literally instead of as wildcards.
    nonisolated static func searchEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\\"*_:()".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
