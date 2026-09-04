import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import MCP

/// Note mutation tools — the heart of "agent, fix my cards".
enum NoteTools {
    static var tools: [AmgiTool] {
        [
            AmgiTool(
                name: "notetypes_list",
                description: """
                    Lists every notetype with its field names and template count. \
                    Consult before add_note so field names match exactly.
                    """,
                inputSchema: Schema.object([:]),
                minimumTier: .readOnly
            ) { ctx, _ in
                let list = try ctx.backend().invoke(.notetypeNames)
                guard !list.isEmpty else { return "(no notetypes)" }
                return try list.map { entry in
                    let nt = try ctx.backend().invoke(.notetype(for: entry.id))
                    let fields = nt.fields.map(\.name).joined(separator: ", ")
                    let kind = nt.config.kind == .cloze ? " [cloze]" : ""
                    return "- '\(entry.name)'\(kind) fields: \(fields)"
                }.joined(separator: "\n")
            },
            AmgiTool(
                name: "add_note",
                description: """
                    Adds one note into a deck. `fields` keys must match the notetype's \
                    field names exactly (see notetypes_list). HTML is allowed; reference \
                    media added via add_media_file as <img src="name.jpg"> or [sound:name.mp3].
                    """,
                inputSchema: Schema.object(
                    [
                        "notetype": Schema.string("Notetype name"),
                        "deck": Schema.string("Full deck name"),
                        "fields": Schema.objectOfStrings("Field name → content"),
                        "tags": Schema.arrayOfStrings("Optional tags"),
                    ],
                    required: ["notetype", "deck", "fields"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let notetypeName = try args.requireString("notetype")
                let deckName = try args.requireString("deck")
                let provided = try args.fieldMap("fields")
                let tags = try args.stringArray("tags")

                let ntEntry = try Resolver.notetypeID(ctx, name: notetypeName)
                let notetype = try ctx.backend().invoke(.notetype(for: ntEntry.id))
                var template = try ctx.backend().invoke(.newNote(notetypeId: ntEntry.id))

                var changedKeys: [String] = []
                for (index, field) in notetype.fields.enumerated()
                where template.fields.indices.contains(index) {
                    if let value = provided[field.name] {
                        template.fields[index] = value
                        changedKeys.append(field.name)
                    }
                }
                let unknownKeys = Set(provided.keys).subtracting(notetype.fields.map(\.name))
                if !unknownKeys.isEmpty {
                    throw ToolError.badArg(
                        "fields",
                        "unknown field(s) for '\(notetype.name)': \(unknownKeys.sorted().joined(separator: ", "))"
                    )
                }
                if template.fields.allSatisfy({ $0.isEmpty }) {
                    throw ToolError.badArg(
                        "fields",
                        "no content provided; expected field(s): \(notetype.fields.map(\.name))"
                    )
                }
                template.tags = tags

                let deck = try Resolver.deckID(ctx, nameOrID: deckName)
                try ctx.backend().invoke(.addNote(template: template, deckId: deck.id))
                return "added note to '\(deck.name)' (\(changedKeys.count) field(s) set)"
            },
            AmgiTool(
                name: "update_note_fields",
                description: """
                    Partially updates a note's fields — only the keys you provide are \
                    changed. Fetch first with get_note to see current values.
                    """,
                inputSchema: Schema.object(
                    [
                        "note_id": Schema.int("Note id"),
                        "fields": Schema.objectOfStrings("Subset of field names → new content"),
                    ],
                    required: ["note_id", "fields"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let id = NoteID(Int64(try args.requireInt("note_id")))
                let patch = try args.fieldMap("fields")

                let note = try ctx.backend().invoke(.getNote(id: id))
                let notetype = try ctx.backend().invoke(.notetype(for: note.mid))
                var values = note.flds.components(separatedBy: "\u{1f}")

                var changed = 0
                for (index, field) in notetype.fields.enumerated()
                where values.indices.contains(index) {
                    if let replacement = patch[field.name] {
                        values[index] = replacement
                        changed += 1
                    }
                }
                let unmatched = Set(patch.keys).subtracting(notetype.fields.map(\.name))
                if !unmatched.isEmpty {
                    throw ToolError.badArg(
                        "fields",
                        "unknown field(s): \(unmatched.sorted().joined(separator: ", "))"
                    )
                }
                guard changed > 0 else {
                    throw ToolError.badArg(
                        "fields",
                        "none of the provided keys matched this notetype's fields"
                    )
                }

                var updated = note
                updated.flds = values.joined(separator: "\u{1f}")
                try ctx.backend().invoke(.updateNote(updated))
                return "updated \(changed) field(s) on note \(id.rawValue)"
            },
            AmgiTool(
                name: "update_note_tags",
                description: "Replaces the full tag list of a note (empty array clears tags).",
                inputSchema: Schema.object(
                    [
                        "note_id": Schema.int("Note id"),
                        "tags": Schema.arrayOfStrings("Complete replacement tag list"),
                    ],
                    required: ["note_id", "tags"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let id = NoteID(Int64(try args.requireInt("note_id")))
                let tags = try args.stringArray("tags")
                let note = try ctx.backend().invoke(.getNote(id: id))
                var updated = note
                updated.tags = tags.joined(separator: " ")
                try ctx.backend().invoke(.updateNote(updated))
                return tags.isEmpty
                    ? "cleared tags on note \(id.rawValue)"
                    : "set tags [\(updated.tags)] on note \(id.rawValue)"
            },
            AmgiTool(
                name: "add_tags",
                description: "Adds tags to multiple notes at once (bulk leech triage etc.).",
                inputSchema: Schema.object(
                    [
                        "note_ids": Schema.intArray("Note ids"),
                        "tags": Schema.arrayOfStrings("Tags to add"),
                    ],
                    required: ["note_ids", "tags"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let ids = try Self.noteIDs(args)
                let tags = try args.stringArray("tags")
                guard !tags.isEmpty else { throw ToolError.badArg("tags", "must be non-empty") }
                try ctx.backend().invoke(.addNoteTags(noteIds: ids, tags: tags.joined(separator: " ")))
                return "added [\(tags.joined(separator: " "))] to \(ids.count) note(s)"
            },
            AmgiTool(
                name: "remove_tags",
                description: "Removes tags from multiple notes.",
                inputSchema: Schema.object(
                    [
                        "note_ids": Schema.intArray("Note ids"),
                        "tags": Schema.arrayOfStrings("Tags to remove"),
                    ],
                    required: ["note_ids", "tags"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let ids = try Self.noteIDs(args)
                let tags = try args.stringArray("tags")
                guard !tags.isEmpty else { throw ToolError.badArg("tags", "must be non-empty") }
                try ctx.backend().invoke(.removeNoteTags(noteIds: ids, tags: tags.joined(separator: " ")))
                return "removed [\(tags.joined(separator: " "))] from \(ids.count) note(s)"
            },
            AmgiTool(
                name: "set_card_flags",
                description: """
                    Sets Anki's colored flags on cards (0=none … 7). Flag 3 is the \
                    conventional marker Anki applies to leeches.
                    """,
                inputSchema: Schema.object(
                    [
                        "card_ids": Schema.intArray("Card ids"),
                        "flag": Schema.int("0–7 (0 clears)"),
                    ],
                    required: ["card_ids", "flag"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let ids = try Self.cardIDs(args, key: "card_ids")
                let flag = try args.requireInt("flag")
                guard (0...7).contains(flag) else { throw ToolError.badArg("flag", "must be 0–7") }
                try ctx.backend().invoke(.setFlag(cardIds: ids, flag: UInt32(flag)))
                return "set flag \(flag) on \(ids.count) card(s)"
            },
            AmgiTool(
                name: "delete_notes",
                description: """
                    Deletes notes and their cards. Destructive; requires confirm=true. \
                    Snapshot taken first when enabled in app settings.
                    """,
                inputSchema: Schema.object(
                    [
                        "note_ids": Schema.intArray("Note ids to delete"),
                        "confirm": Schema.bool("Must be true"),
                    ],
                    required: ["note_ids", "confirm"]
                ),
                minimumTier: .full,
                mutates: true,
                destructive: true
            ) { ctx, args in
                guard try args.requireBool("confirm") else {
                    throw ToolError.badArg("confirm", "must be true — this permanently deletes the notes")
                }
                let ids = try Self.noteIDs(args)
                guard !ids.isEmpty else { return "nothing to delete" }
                for id in ids {
                    try ctx.backend().invoke(.removeNote(id: id))
                }
                return "deleted \(ids.count) note(s): \(ids.map { String($0.rawValue) }.joined(separator: ", "))"
            },
            AmgiTool(
                name: "undo_last_action",
                description: """
                    Undoes the most recent undoable collection action (notes/deck ops). \
                    Safety net after an agent edit that went wrong.
                    """,
                inputSchema: Schema.object([:]),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, _ in
                let hasUndo: Bool = try ctx.backend().invoke(.hasUndoableAction)
                guard hasUndo else { return "nothing to undo" }
                try ctx.backend().invoke(.undoLastAction)
                return "undone"
            },
        ]
    }

    static func noteIDs(_ args: ToolArgs) throws -> [NoteID] {
        try intValues(args, key: "note_ids").map { NoteID(Int64($0)) }
    }

    static func cardIDs(_ args: ToolArgs, key: String) throws -> [CardID] {
        try intValues(args, key: key).map { CardID(Int64($0)) }
    }

    private static func intValues(_ args: ToolArgs, key: String) throws -> [Int] {
        guard let value = args.raw[key] else { throw ToolError.missingArg(key) }
        guard case .array(let items) = value else {
            throw ToolError.badArg(key, "expected array of integers")
        }
        return try items.map { item in
            guard case .int(let i) = item else {
                throw ToolError.badArg(key, "expected array of integers")
            }
            return i
        }
    }
}
