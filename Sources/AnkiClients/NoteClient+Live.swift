import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
public import Dependencies
import DependenciesMacros

extension NoteClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.notesService) var notes
        @Dependency(\.ankiBackend) var backend

        return Self(
            fetch: { noteId in
                try await backendOffload { try notes.getNote(noteId) }
            },
            search: { query, limit in
                try await backendOffload {
                    let ids = try notes.searchNoteIds(query)
                    let bounded = Array(ids.prefix(limit ?? 5000))

                    let firstPageSize = min(bounded.count, 50)
                    var results: [NoteRecord] = []
                    results.reserveCapacity(bounded.count)

                    for nid in bounded.prefix(firstPageSize) {
                        if let note = try? notes.getNote(nid) {
                            results.append(note)
                        }
                    }

                    for nid in bounded.dropFirst(firstPageSize) {
                        results.append(NoteRecord(
                            id: nid, guid: "", mid: NotetypeID(0), mod: 0,
                            tags: "", flds: "", sfld: "Loading...", csum: 0
                        ))
                    }

                    return results
                }
            },
            searchAll: { query, limit in
                try await backendOffload {
                    let ids = try notes.searchNoteIds(query)
                    let bounded = Array(ids.prefix(limit ?? Int.max))
                    var results: [NoteRecord] = []
                    results.reserveCapacity(bounded.count)
                    // No lazy placeholders — every record gets a real
                    // backend fetch. Skips IDs that fail to load (deleted
                    // or otherwise unreachable) rather than aborting the
                    // whole batch.
                    for nid in bounded {
                        if let note = try? notes.getNote(nid) {
                            results.append(note)
                        }
                    }
                    return results
                }
            },
            searchIds: { query, order in
                try await backendOffload {
                    try backend.invoke(.searchNoteIds(query: query, order: order))
                }
            },
            deleteBatch: { noteIds in
                guard !noteIds.isEmpty else { return }
                try await backendOffload {
                    _ = try backend.invoke(.removeNotes(noteIds: noteIds))
                }
            },
            validateQuery: { query in
                try await backendOffload {
                    try backend.invoke(.buildSearchString(query: query))
                }
            },
            composeQuery: { existing, additional, joiner in
                try await backendOffload {
                    try backend.invoke(
                        .joinSearchNodes(existing: existing, additional: additional, joiner: joiner)
                    )
                }
            },
            findAndReplace: { noteIds, search, replacement, regex, matchCase, fieldName in
                try await backendOffload {
                    try backend.invoke(.findAndReplace(
                        noteIds: noteIds,
                        search: search,
                        replacement: replacement,
                        isRegex: regex,
                        matchCase: matchCase,
                        fieldName: fieldName
                    ))
                }
            },
            save: { note in
                try await backendOffload { try notes.saveNote(note) }
            },
            delete: { noteId in
                try await backendOffload { try notes.deleteNote(noteId) }
            }
        )
    }()
}
