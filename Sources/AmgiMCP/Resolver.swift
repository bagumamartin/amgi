import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge

/// Shared resolution helpers: agents address decks/notetypes by *name*
/// (what they see in tool output), never by raw ids unless they round-
/// tripped one from a previous call.
enum Resolver {
    static func deckTree(_ ctx: EngineContext) throws -> [DeckTreeNode] {
        try ctx.backend().invoke(.deckTree(at: .distantPast))
    }

    /// Matches a deck by full name (case-insensitive) or numeric id.
    static func deckID(_ ctx: EngineContext, nameOrID: String) throws -> DeckInfo {
        // Include each root node itself — flattened() yields only
        // descendants, which would hide top-level decks.
        let flat = try deckTree(ctx).flatMap { [$0.asDeckInfo] + $0.flattened() }
        if let id = Int64(nameOrID), let byID = flat.first(where: { $0.id.rawValue == id }) {
            return byID
        }
        guard let match = flat.first(where: { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame })
        else {
            let names = flat.map(\.name).sorted().joined(separator: ", ")
            throw ToolError.notFound("deck '\(nameOrID)' (known decks: \(names))")
        }
        return match
    }

    static func notetypeID(_ ctx: EngineContext, name: String) throws -> NotetypeNameId {
        let list = try ctx.backend().invoke(.notetypeNames)
        guard let match = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let names = list.map(\.name).sorted().joined(separator: ", ")
            throw ToolError.notFound("notetype '\(name)' (known notetypes: \(names))")
        }
        return match
    }
}

