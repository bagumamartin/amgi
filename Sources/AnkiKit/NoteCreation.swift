/// Result of adding one note. The ID and precise invalidation payload let UI,
/// App Intents, and future assistants return/open the created item and publish
/// the same collection activity without re-querying the engine.
public struct NoteCreation: Equatable, Sendable {
    public let noteID: NoteID
    public let changes: CollectionChanges

    public init(noteID: NoteID, changes: CollectionChanges) {
        self.noteID = noteID
        self.changes = changes
    }
}
