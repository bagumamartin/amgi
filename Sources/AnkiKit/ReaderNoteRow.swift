/// One note behind an Anki-deck reader book, as the `readerNotes` aux method
/// returns it: only the fields the caller asked for, keyed by field name.
public struct ReaderNoteRow: Sendable, Equatable, Codable {
    public let id: Int64
    public let notetypeId: Int64
    public let fields: [String: String]

    public init(id: Int64, notetypeId: Int64, fields: [String: String]) {
        self.id = id
        self.notetypeId = notetypeId
        self.fields = fields
    }
}

public struct ReaderNotesResult: Sendable, Equatable, Codable {
    public let notes: [ReaderNoteRow]

    public init(notes: [ReaderNoteRow]) {
        self.notes = notes
    }
}
