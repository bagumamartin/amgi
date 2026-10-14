import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
import Dependencies
import Foundation

/// Synchronous typed service adapters inside the backend's recursive lifecycle
/// lock. Validation and commit are indivisible with respect to ALL backend RPCs,
/// including manual edits, MCP operations and collection lifecycle transitions.
enum AssistantCollectionMutator {
    struct Result: Sendable { var outcome: String; var targets: [Int64]; var appliedFields: [String]? = nil }
    @concurrent static func apply(original: AssistantToolArguments, approved: AssistantToolArguments, expected: String, profileID: String, activation: UUID) async throws -> Result {
        @Dependency(\.ankiBackend) var backend
        @Dependency(\.notesService) var notes
        @Dependency(\.decksService) var decks
        return try backend.withLifecycleAccess {
            try Task.checkCancellation()
            guard backend.collectionActivationID == activation else { throw AgentToolError.invalid("The collection activation changed") }
            let actual = try fingerprint(original, profileID: profileID, backend: backend, notes: notes, decks: decks)
            guard actual == expected else { throw AgentToolError.invalid("Targets changed since review. Propose and review them again.") }
            try Task.checkCancellation()
            let args = approved, ids = args.ids ?? []
            let cardIDs = ids.map { CardID($0) }
            switch args.action {
            case "add_note":
                var template = try notes.newNote(NotetypeID(args.notetypeID!))
                template.fields = args.fields!; template.tags = args.tags ?? []
                let created = try backend.invoke(.addNoteWithResult(template: template, deckId: DeckID(args.deckID!)))
                return Result(outcome: "Created note \(created.noteID.rawValue) in deck \(args.deckID!) using the reviewed field contents.", targets: [created.noteID.rawValue], appliedFields: template.fields)
            case "edit_note":
                var note = try notes.getNote(NoteID(ids[0]))
                note.flds = args.fields!.joined(separator: "\u{1f}"); try notes.saveNote(note)
            case "delete_notes": _ = try backend.invoke(.removeNotes(noteIds: ids.map { NoteID($0) }))
            case "set_tags":
                var committed: [Int64] = []
                do {
                    for id in ids {
                        try Task.checkCancellation()
                        var note = try notes.getNote(NoteID(id))
                        note.tags = " " + (args.tags ?? []).joined(separator: " ") + " "
                        try notes.saveNote(note); committed.append(id)
                    }
                } catch {
                    return Result(outcome: "Applied tags to \(committed); remaining changes stopped: \(error.localizedDescription)", targets: committed)
                }
            case "suspend_cards": try backend.invoke(.suspendCards(cardIds: cardIDs, noteIds: []))
            case "restore_cards": try backend.invoke(.restoreBuriedAndSuspendedCards(cardIds: cardIDs))
            case "bury_cards": try backend.invoke(.buryUserCards(cardIds: cardIDs, noteIds: []))
            case "flag_cards":
                guard let flag = UInt32(args.value ?? ""), flag <= 7 else { throw AgentToolError.invalid("Flag must be 0–7") }
                try backend.invoke(.setFlag(cardIds: cardIDs, flag: flag))
            case "set_due": try backend.invoke(.setDueDate(cardIds: cardIDs, daysExpression: args.value ?? ""))
            case "move_cards": _ = try backend.invoke(.setDeck(cardIds: cardIDs, deckId: DeckID(args.deckID!)))
            case "forget_cards": try backend.invoke(.scheduleCardsAsNew(cardIds: cardIDs, log: true, restorePosition: false, resetCounts: false))
            case "create_deck": _ = try decks.createDeck(args.name!)
            case "rename_deck": _ = try decks.renameDeck(DeckID(args.deckID!), args.name!)
            case "update_template":
                var type = try backend.invoke(.notetype(for: NotetypeID(args.notetypeID!)))
                let ordinal = Int(ids[0])
                type.templates[ordinal].config.qFormat = args.fields![0]
                type.templates[ordinal].config.aFormat = args.fields![1]
                type.config.css = args.fields![2]
                try backend.invoke(.updateNotetype(type))
            case "rename_notetype":
                var type = try backend.invoke(.notetype(for: NotetypeID(args.notetypeID!)))
                type.name = args.name!; try backend.invoke(.updateNotetype(type))
            case "clone_notetype":
                var type = try backend.invoke(.notetype(for: NotetypeID(args.notetypeID!)))
                type.id = NotetypeID(0); type.name = args.name!; type.mtimeSecs = 0; type.usn = -1; type.config.originalID = nil
                for i in type.templates.indices { type.templates[i].config.id = nil }
                _ = try backend.invoke(.addNotetype(type))
            case "undo": try backend.invoke(.undoLastAction)
            case "redo": try backend.invoke(.redoLastAction)
            default: throw AgentToolError.invalid("Unsupported reviewed operation")
            }
            return Result(outcome: "Committed \(args.action) successfully for the reviewed targets.", targets: ids, appliedFields: args.fields)
        }
    }
    private static func fingerprint(_ args: AssistantToolArguments, profileID: String, backend: AnkiBackend, notes: NotesService, decks: DecksService) throws -> String {
        var parts = [profileID, args.action]
        switch args.action {
        case "edit_note", "delete_notes", "set_tags":
            for id in args.ids ?? [] {
                let note = try notes.getNote(NoteID(id))
                let cardIDs = try backend.invoke(.cardIDsOfNote(id: NoteID(id)))
                let cards = try cardIDs.map { try backend.invoke(.getCard(id: $0)) }
                parts += [String(describing: note), String(describing: cards)]
            }
        case "add_note":
            let type = try backend.invoke(.notetype(for: NotetypeID(args.notetypeID!)))
            guard let deck = try decks.fetchAll().first(where: { $0.id.rawValue == args.deckID }) else { throw AgentToolError.invalid("Destination deck missing") }
            parts += [String(describing: type), String(describing: deck)]
        case "suspend_cards", "restore_cards", "bury_cards", "flag_cards", "set_due", "move_cards", "forget_cards":
            for id in args.ids ?? [] { parts.append(String(describing: try backend.invoke(.getCard(id: CardID(id))))) }
            if args.action == "move_cards" {
                guard let deck = try decks.fetchAll().first(where: { $0.id.rawValue == args.deckID }) else { throw AgentToolError.invalid("Destination deck missing") }
                parts.append(String(describing: deck))
            }
        case "create_deck", "rename_deck": parts.append(String(describing: try decks.fetchAll()))
        case "update_template", "rename_notetype", "clone_notetype": parts.append(String(describing: try backend.invoke(.notetype(for: NotetypeID(args.notetypeID!)))))
        case "undo", "redo": parts.append(String(describing: try backend.invoke(.undoStatus)))
        default: throw AgentToolError.invalid("Unsupported snapshot")
        }
        return parts.joined(separator: "\n")
    }
}
