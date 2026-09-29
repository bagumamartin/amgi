public import AnkiKit
public import AnkiProtoBridge
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct NoteClient: Sendable {
    public var fetch: @Sendable (_ noteId: NoteID) async throws -> NoteRecord?
    /// Browser-friendly search — returns the first 50 hits with full
    /// fields and the rest as lazy placeholders ("Loading…" sfld) so the
    /// list doesn't stall on large results. Callers that need every
    /// record's real content (e.g. the reader's chapter loader) must
    /// use `searchAll` instead.
    public var search: @Sendable (_ query: String, _ limit: Int?) async throws -> [NoteRecord]
    /// Eager search — returns full NoteRecords for every hit, no lazy
    /// placeholders. Slower for large results but required when the
    /// caller reads `flds` immediately.
    public var searchAll: @Sendable (_ query: String, _ limit: Int?) async throws -> [NoteRecord]
    /// Raw id search with engine-side ordering (browse-redesign-spec D3:
    /// sorting never happens client-side over paged windows).
    public var searchIds: @Sendable (_ query: String, _ order: SearchOrder?) async throws -> [NoteID]
    /// Single-transaction batch delete — one engine undo entry.
    public var deleteBatch: @Sendable (_ noteIds: [NoteID]) async throws -> Void
    /// Validates/canonicalizes a query (BuildSearchString). Throws on
    /// grammar errors so callers can surface them inline.
    public var validateQuery: @Sendable (_ query: String) async throws -> String
    /// Engine-canonical AND/OR composition of two parsable fragments.
    public var composeQuery: @Sendable (_ existing: String, _ additional: String, _ joiner: SearchJoiner) async throws -> String
    /// Bulk field/tag substitution across notes; returns changed count.
    /// Empty `noteIds` means collection-wide (desktop parity: unchecking
    /// "selected notes" clears the scope to every note).
    public var findAndReplace: @Sendable (_ noteIds: [NoteID], _ search: String, _ replacement: String, _ regex: Bool, _ matchCase: Bool, _ fieldName: String?) async throws -> Int
    /// Union of field names across notes (Find & Replace picker source).
    public var fieldNames: @Sendable (_ noteIds: [NoteID]) async throws -> [String]
    /// Existing cloze ordinals for draft content (cloze-same-number init).
    public var clozeNumbers: @Sendable (_ fields: [String], _ notetypeId: NotetypeID) async throws -> [UInt32]
    public var save: @Sendable (_ note: NoteRecord) async throws -> Void
    public var delete: @Sendable (_ noteId: NoteID) async throws -> Void
    /// Creates a note from a positional field array.
    ///
    /// `fields` is **positional** — indexed by the notetype's field ordinals, not
    /// by name. A caller that projects onto named fields has to pass them in the
    /// notetype's own order, and a field with nothing to say must still occupy
    /// its slot as an empty string: a short array does not skip a field, it
    /// shifts every field after the gap into the wrong column.
    ///
    /// This is the only write path that takes a notetype and a field array
    /// rather than an edited `NoteRecord`, which is what a feature that
    /// *generates* a note needs — the reader's card parks build fields rather
    /// than round-trip a record through the editor.
    public var add: @Sendable (
        _ notetypeID: NotetypeID,
        _ deckID: DeckID,
        _ fields: [String],
        _ tags: [String]
    ) async throws -> Void
}

extension NoteClient: TestDependencyKey {
    public static let testValue = NoteClient()
}

extension DependencyValues {
    public var noteClient: NoteClient {
        get { self[NoteClient.self] }
        set { self[NoteClient.self] = newValue }
    }
}
