import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import MCP

/// Note/card search and inspection.
enum SearchTools {
    static var tools: [AmgiTool] {
        [
            AmgiTool(
                name: "search_notes",
                description: """
                    Runs an Anki search over notes and returns matches with ids, sort \
                    field, and tags. Query syntax: standard Anki (e.g. "tag:leech", \
                    "deck:Japanese is:due", "front:cat"). Use returned note ids with \
                    get_note / update_note_fields.
                    """,
                inputSchema: Schema.object(
                    [
                        "query": Schema.string("Anki search expression; empty = all notes"),
                        "limit": Schema.int("Max matches to detail (default 20, ids capped at 200)"),
                    ],
                    required: ["query"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let query = try args.requireString("query")
                let limit = args.optionalInt("limit", default: 20)
                let ids = try ctx.backend().invoke(.searchNoteIds(query: query))
                guard !ids.isEmpty else { return "no matches for '\(query)'" }
                let detailed = ids.prefix(min(limit, 200))
                var lines: [String] = ["\(ids.count) match(es); showing \(detailed.count):"]
                for id in detailed {
                    let note = try ctx.backend().invoke(.getNote(id: id))
                    lines.append("- id \(id.rawValue) | \(note.sfld) | tags: \(note.tags.isEmpty ? "(none)" : note.tags)")
                }
                if ids.count > detailed.count {
                    lines.append("… \(ids.count - detailed.count) more (raise `limit` or narrow the query)")
                }
                return lines.joined(separator: "\n")
            },
            AmgiTool(
                name: "search_cards",
                description: "Runs an Anki search over cards, returning card ids with deck and scheduling state.",
                inputSchema: Schema.object(
                    [
                        "query": Schema.string("Anki card search (e.g. \"deck:Default is:due\", \"flag:3\")"),
                        "limit": Schema.int("Max cards to detail (default 20, ids capped at 200)"),
                    ],
                    required: ["query"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let query = try args.requireString("query")
                let limit = args.optionalInt("limit", default: 20)
                let ids = try ctx.backend().invoke(.searchCardIds(query: query))
                guard !ids.isEmpty else { return "no matches for '\(query)'" }
                let deckNames = Dictionary(
                    uniqueKeysWithValues: try Resolver.deckTree(ctx).flatMap { $0.flattened() }
                        .map { ($0.id, $0.name) }
                )
                let detailed = ids.prefix(min(limit, 200))
                var lines: [String] = ["\(ids.count) match(es); showing \(detailed.count):"]
                for id in detailed {
                    let card = try ctx.backend().invoke(.getCard(id: id))
                    let deck = deckNames[card.did].map { "'\($0)'" } ?? "deck \(card.did.rawValue)"
                    lines.append(
                        "- id \(id.rawValue) | \(deck) | \(Self.state(card)) | ivl:\(card.ivl) reps:\(card.reps) lapses:\(card.lapses) flag:\(card.flags & 0b111)"
                    )
                }
                if ids.count > detailed.count {
                    lines.append("… \(ids.count - detailed.count) more")
                }
                return lines.joined(separator: "\n")
            },
            AmgiTool(
                name: "get_note",
                description: "Fetches one note: every field by name, tags, notetype, and card count.",
                inputSchema: Schema.object(
                    ["note_id": Schema.int("Note id from search_notes")],
                    required: ["note_id"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let id = NoteID(Int64(try args.requireInt("note_id")))
                let note = try ctx.backend().invoke(.getNote(id: id))
                let notetype = try ctx.backend().invoke(.notetype(for: note.mid))
                let fieldValues = note.flds.components(separatedBy: "\u{1f}")
                var lines = [
                    "note \(id.rawValue) | notetype '\(notetype.name)' | tags: \(note.tags.isEmpty ? "(none)" : note.tags)"
                ]
                for (index, field) in notetype.fields.enumerated() {
                    let value = fieldValues.indices.contains(index) ? fieldValues[index] : ""
                    lines.append("  \(field.name): \(value)")
                }
                let cardIds = try ctx.backend().invoke(.searchCardIds(query: "nid:\(id.rawValue)"))
                lines.append("  cards: \(cardIds.map { String($0.rawValue) }.joined(separator: ", "))")
                return lines.joined(separator: "\n")
            },
            AmgiTool(
                name: "get_card",
                description: "Fetches one card: scheduling state, deck, and its note's fields.",
                inputSchema: Schema.object(
                    ["card_id": Schema.int("Card id from search_cards")],
                    required: ["card_id"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let id = CardID(Int64(try args.requireInt("card_id")))
                let card = try ctx.backend().invoke(.getCard(id: id))
                let note = try ctx.backend().invoke(.getNote(id: card.nid))
                let notetype = try ctx.backend().invoke(.notetype(for: note.mid))
                let fieldValues = note.flds.components(separatedBy: "\u{1f}")
                var lines = [
                    """
                    card \(id.rawValue) | \(Self.state(card)) | deck \(card.did.rawValue) | \
                    due:\(card.due) ivl:\(card.ivl) ease:\(card.factor) reps:\(card.reps) lapses:\(card.lapses)
                    """
                ]
                for (index, field) in notetype.fields.enumerated() {
                    let value = fieldValues.indices.contains(index) ? fieldValues[index] : ""
                    lines.append("  \(field.name): \(value)")
                }
                return lines.joined(separator: "\n")
            },
        ]
    }

    /// Human-readable card state from the raw type/queue columns.
    static func state(_ card: CardRecord) -> String {
        let queue: String
        switch card.queue {
        case -3: queue = "sibling-buried"
        case -2: queue = "buried"
        case -1: queue = "suspended"
        case 0: queue = "new"
        case 1: queue = "learning"
        case 2: queue = "review"
        case 3: queue = "day-learning"
        default: queue = "queue:\(card.queue)"
        }
        return queue
    }
}
