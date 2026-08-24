import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import MCP

/// Deck inspection and lifecycle tools.
enum DeckTools {
    static var tools: [AmgiTool] {
        [
            AmgiTool(
                name: "deck_tree",
                description: """
                    Full deck hierarchy with today's due counts (new / learning / review) \
                    per deck, including subdecks. Use this to orient before any other call.
                    """,
                inputSchema: .object([:]),
                minimumTier: .readOnly
            ) { ctx, _ in
                let tree = try Resolver.deckTree(ctx)
                var lines: [String] = []
                func walk(_ nodes: [DeckTreeNode], depth: Int) {
                    for node in nodes {
                        let indent = String(repeating: "  ", count: depth)
                        lines.append(
                            "\(indent)\(node.name) (id \(node.id.rawValue)) — new:\(node.counts.newCount) learn:\(node.counts.learnCount) review:\(node.counts.reviewCount)"
                        )
                        walk(node.children, depth: depth + 1)
                    }
                }
                walk(tree, depth: 0)
                return lines.isEmpty ? "(no decks)" : lines.joined(separator: "\n")
            },
            AmgiTool(
                name: "collection_status",
                description: """
                    Reports which profile this server exposes, whether the \
                    collection is currently open, and why not if it isn't \
                    (Amgi.app holds an exclusive engine lock while running).
                    """,
                inputSchema: .object([:]),
                minimumTier: .readOnly
            ) { ctx, _ in
                var lines = [
                    "profile: \(ctx.paths.profileID)",
                    "collection: \(ctx.paths.collectionPath)",
                    "tier: \(ctx.settings.tier.rawValue)",
                ]
                do {
                    _ = try ctx.backend()
                    lines.append("mode: \(ctx.engine.modeDescription)")
                } catch {
                    lines.append("state: closed — \(ctx.engine.lastErrorDescription ?? error.localizedDescription)")
                }
                return lines.joined(separator: "\n")
            },
            AmgiTool(
                name: "deck_counts",
                description: "Due counts (new/learning/review) for one deck by name or id.",
                inputSchema: Schema.object(
                    ["deck": Schema.string("Deck full name (e.g. \"Default\") or numeric id")],
                    required: ["deck"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let deck = try Resolver.deckID(ctx, nameOrID: try args.requireString("deck"))
                return "new:\(deck.counts.newCount) learn:\(deck.counts.learnCount) review:\(deck.counts.reviewCount)"
            },
            AmgiTool(
                name: "create_deck",
                description: "Creates a deck by full name (parent decks are created implicitly by Anki naming).",
                inputSchema: Schema.object(
                    ["name": Schema.string("Full deck path, e.g. \"Languages::Japanese::Vocab\"")],
                    required: ["name"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let name = try args.requireString("name")
                let template = try ctx.backend().invoke(.newDeck)
                _ = try ctx.backend().invoke(.addDeck(template: template, name: name))
                return "created deck '\(name)'"
            },
            AmgiTool(
                name: "rename_deck",
                description: "Renames a deck (full path). Cards move with it.",
                inputSchema: Schema.object(
                    [
                        "deck": Schema.string("Current full deck name or id"),
                        "new_name": Schema.string("New full deck name"),
                    ],
                    required: ["deck", "new_name"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let deck = try Resolver.deckID(ctx, nameOrID: try args.requireString("deck"))
                let newName = try args.requireString("new_name")
                _ = try ctx.backend().invoke(.renameDeck(deckId: deck.id, newName: newName))
                return "renamed '\(deck.name)' → '\(newName)'"
            },
            AmgiTool(
                name: "delete_deck",
                description: """
                    Deletes a deck AND all its cards. Destructive; requires confirm=true. \
                    A snapshot of the collection is taken first when enabled in app settings.
                    """,
                inputSchema: Schema.object(
                    [
                        "deck": Schema.string("Full deck name or id"),
                        "confirm": Schema.bool("Must be true"),
                    ],
                    required: ["deck", "confirm"]
                ),
                minimumTier: .full,
                mutates: true,
                destructive: true
            ) { ctx, args in
                guard try args.requireBool("confirm") else {
                    throw ToolError.badArg("confirm", "must be true — this deletes the deck and its cards")
                }
                let deck = try Resolver.deckID(ctx, nameOrID: try args.requireString("deck"))
                guard deck.id.rawValue != 1 else {
                    throw ToolError.badArg("deck", "the built-in Default deck cannot be deleted")
                }
                _ = try ctx.backend().invoke(.removeDecks(deckIds: [deck.id]))
                return "deleted deck '\(deck.name)'"
            },
        ]
    }
}
