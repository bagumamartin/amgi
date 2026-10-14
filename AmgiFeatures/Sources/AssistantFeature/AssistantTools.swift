import AmgiEmbeddings
import AmgiAppCore
import AmgiAppShared
import AmgiCardWeb
import AmgiReviewCore
import AnkiBackend
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import ManifoldKit
import Observation

/// One JSON tool contract and executor set for every provider. Backends may
/// translate schema/transcript formats, but never change approval or execution.
@MainActor enum AssistantToolCatalog {
    static func registry(host: AssistantToolHost) -> ToolRegistry {
        ToolRegistry(tools: [AssistantCollectionTool(host: host, writes: false), AssistantCollectionTool(host: host, writes: true), AssistantNavigationTool(host: host)])
    }
}

struct AssistantToolArguments: Codable, Sendable, Hashable {
    var action: String
    var query: String?
    var ids: [Int64]?
    var deckID: Int64?
    var notetypeID: Int64?
    var name: String?
    var fields: [String]?
    var tags: [String]?
    var value: String?
}

extension AssistantToolArguments {
    private enum CodingKeys: String, CodingKey { case action, query, ids, deckID, notetypeID, name, fieldContents, fields, tags, value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        ids = try c.decodeIfPresent([Int64].self, forKey: .ids)
        deckID = try c.decodeIfPresent(Int64.self, forKey: .deckID)
        notetypeID = try c.decodeIfPresent(Int64.self, forKey: .notetypeID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // Retain decoding of persisted pre-overhaul calls; advertise only the
        // unambiguous fieldContents name to every provider going forward.
        fields = try c.decodeIfPresent([String].self, forKey: .fieldContents) ?? c.decodeIfPresent([String].self, forKey: .fields)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        value = try c.decodeIfPresent(String.self, forKey: .value)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(query, forKey: .query)
        try c.encodeIfPresent(ids, forKey: .ids)
        try c.encodeIfPresent(deckID, forKey: .deckID)
        try c.encodeIfPresent(notetypeID, forKey: .notetypeID)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(fields, forKey: .fieldContents)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(value, forKey: .value)
    }
}

struct AssistantChangeItem: Identifiable, Sendable {
    let id: Int64
    let title: String
    let before: String
    var after: String
    var selected = true
}

/// Approval is per proposal and never a sticky "allow all" permission. The
/// executor re-fetches its exact target snapshot while holding the collection
/// mutation lease. A changed target must be proposed and reviewed again.
@MainActor @Observable
final class AssistantToolHost: ToolApprovalGate {
    let profile: ProfileContext
    var pendingTitle: String?
    var pendingItems: [AssistantChangeItem] = []
    var pendingConsequence = ""
    var errorMessage: String?
    var citations: [AssistantCitation] = []
    var sources: [AssistantSource] = []
    @ObservationIgnored private var continuation: CheckedContinuation<ToolApprovalDecision, Never>?
    @ObservationIgnored private var staged: (arguments: AssistantToolArguments, snapshot: String)?
    @ObservationIgnored private var approved: (arguments: AssistantToolArguments, snapshot: String)?
    @ObservationIgnored @Dependency(\.ankiBackend) private var backend
    @ObservationIgnored @Dependency(\.noteClient) private var notes
    @ObservationIgnored @Dependency(\.cardClient) private var cards
    @ObservationIgnored @Dependency(\.deckClient) private var decks
    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypes
    @ObservationIgnored @Dependency(\.collectionStore) private var store
    var openNote: @MainActor (AssistantCitation) -> Void = { _ in }
    var openRoute: @MainActor (AssistantRoute) -> Void = { _ in }
    var canEditDraft = false
    var activeChatID: UUID?
    var receipts: [CommitReceipt] = []
    struct CommitReceipt: Codable, Identifiable {
        var id = UUID()
        var chatID: UUID?
        var timestamp = Date()
        var operation: String
        var targets: [Int64]
        var outcome: String
    }
    private var receiptURL: URL {
        AccountStore.profileDirectory(for: AccountStore.shared.current.id).appendingPathComponent("assistant-commits-\(profile.id).json")
    }

    init(profile: ProfileContext) {
        self.profile = profile
        if let data = try? Data(contentsOf: receiptURL), let saved = try? JSONDecoder().decode([CommitReceipt].self, from: data) { receipts = saved }
    }
    private func recordCommit(_ args: AssistantToolArguments, outcome: String, targets: [Int64]? = nil) {
        // Read the latest journal before appending, so other windows' commits
        // are preserved even when this presentation has an older snapshot.
        let old = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode([CommitReceipt].self, from: $0) } ?? []
        receipts = old + [CommitReceipt(chatID: activeChatID, operation: args.action, targets: targets ?? args.ids ?? [], outcome: outcome)]
        do { try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic) }
        catch { errorMessage = "The change committed, but its receipt could not be saved: \(error.localizedDescription)" }
    }
    func approve(_ call: ToolCall) async -> ToolApprovalDecision {
        guard call.toolName == "change_collection", continuation == nil,
              let arguments = try? JSONDecoder().decode(AssistantToolArguments.self, from: Data(call.arguments.utf8)) else {
            return .denied(reason: "Unsupported or overlapping change request")
        }
        do {
            let snapshot = try await snapshot(arguments, prepare: true)
            try checkProfile()
            staged = (arguments, snapshot)
            canEditDraft = ["add_note", "edit_note", "update_template"].contains(arguments.action)
            pendingTitle = arguments.action.replacingOccurrences(of: "_", with: " ").capitalized
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { @MainActor [weak self] in self?.resolve(approve: false) } }
        } catch { return .denied(reason: error.localizedDescription) }
    }
    func resolve(approve: Bool) {
        if approve, let staged, pendingItems.contains(where: \.selected), profile.isCurrent(AccountStore.shared.selectedContext) {
            var args = staged.arguments
            if let ids = args.ids, !["edit_note", "update_template"].contains(args.action) { args.ids = ids.filter { id in pendingItems.contains { $0.id == id && $0.selected } } }
            // Individual note fields are editable before approval.
            if args.action == "edit_note" || args.action == "add_note" || args.action == "update_template" { args.fields = pendingItems.map { $0.selected ? $0.after : $0.before } }
            approved = (args, staged.snapshot)
            continuation?.resume(returning: .approved)
        } else { approved = nil; continuation?.resume(returning: .denied(reason: "Change declined or interrupted")) }
        continuation = nil; staged = nil; pendingTitle = nil; pendingItems = []
    }
    func cancel() { resolve(approve: false); approved = nil }
    func checkProfile() throws {
        guard profile.isCurrent(AccountStore.shared.selectedContext) else { throw AssistantError.profileChanged }
        try Task.checkCancellation()
    }
    func read(_ args: AssistantToolArguments) async throws -> String {
        try checkProfile()
        guard ReviewSessionActivity.shared.beginExternalRead() else { throw CancellationError() }
        defer { ReviewSessionActivity.shared.endRead() }
        let result: String
        switch args.action {
        case "list_decks", "get_study_overview", "decks", "study_overview":
            let tree = try await decks.fetchTree()
            func payload(_ node: DeckTreeNode) -> JSONSchemaValue {
                .object(["id": .integer(node.id.rawValue), "name": .string(node.fullName),
                         "new": .integer(Int64(node.counts.newCount)), "learning": .integer(Int64(node.counts.learnCount)),
                         "review": .integer(Int64(node.counts.reviewCount)), "children": .array(node.children.map(payload))])
            }
            result = try Self.json(.array(tree.map(payload)))
        case "retrieve":
            let hits = try await CollectionRetrievalCoordinator.shared.search(args.query ?? "", limit: 8)
            sources = hits.map { hit in
                let segment = hit.segment
                return AssistantSource(id: segment.id, sourceID: segment.sourceID, title: segment.title, excerpt: String(segment.text.prefix(4000)), anchor: segment.anchor, url: segment.sourceURL, modality: segment.modality.rawValue)
            }
            citations = hits.compactMap { hit in
                guard hit.segment.sourceID.hasPrefix("note:"), let id = Int64(hit.segment.sourceID.dropFirst(5)) else { return nil }
                return AssistantCitation(id: id, title: hit.segment.title, profile: profile)
            }
            result = hits.map { "Source \($0.segment.sourceID), anchor \($0.segment.anchor), title \($0.segment.title): \($0.segment.text)" }.joined(separator: "\n")
        case "search_notes", "notes", "search":
            let records = try await notes.searchAll(args.query ?? "", 8)
            citations = records.map { AssistantCitation(id: $0.id.rawValue, title: String(CardText.plainText($0.sfld).prefix(100)), profile: profile) }
            sources = citations.map(AssistantSource.init(citation:))
            result = records.map { "Note \($0.id.rawValue) | \(CardText.plainText($0.flds)) | tags: \($0.tags)" }.joined(separator: "\n")
        case "get_note", "note":
            guard let id = args.ids?.first, let note = try await notes.fetch(NoteID(id)) else { throw AgentToolError.invalid("Note does not exist") }
            citations = [AssistantCitation(id: id, title: String(CardText.plainText(note.sfld).prefix(100)), profile: profile)]
            sources = citations.map(AssistantSource.init(citation:))
            result = "Note \(id), notetype \(note.mid.rawValue): \(note.flds), tags \(note.tags)"
        case "get_card", "card":
            guard let id = args.ids?.first else { throw AgentToolError.invalid("Card ID required") }
            result = String(describing: try await cards.getCard(CardID(id)))
        case "get_notetype", "notetype":
            guard let id = args.notetypeID else { throw AgentToolError.invalid("notetypeID is required. First call list_notetypes to look up the actual ID.") }
            let type = try await notetypes.get(NotetypeID(id))
            result = try Self.json(.object([
                "id": .integer(type.id.rawValue), "name": .string(type.name),
                "fields": .array(type.fields.map { .string($0.name) }), "css": .string(type.config.css),
                "templates": .array(type.templates.map { .object(["name": .string($0.name), "front": .string($0.config.qFormat), "back": .string($0.config.aFormat)]) })
            ]))
        case "get_deck_config", "deck_config":
            guard let id = args.deckID else { throw AgentToolError.invalid("Deck ID required") }
            result = String(describing: try await decks.getDeckConfig(DeckID(id)))
        case "capabilities":
            result = "Read: hybrid retrieval, notes, cards, deck tree and counts, notetypes/templates, deck configuration, live review, undo. Reviewed changes: add/edit/delete notes, tags, move/suspend/bury/flag/due/forget cards, create/rename decks, rename/clone notetypes, update templates. Navigation: app sections, Browse query, Review deck. Dedicated existing workflows: Settings, import, export, sync. Active review ratings are exclusively user controlled."
        case "list_notetypes", "notetypes":
            let types = try await notetypes.listAll()
            result = try Self.json(.array(types.map { .object(["id": .integer($0.id.rawValue), "name": .string($0.name)]) }))
        case "get_review_context", "review_context": result = ReviewSessionContext.shared.encodedSnapshot().flatMap { String(data: $0, encoding: .utf8) } ?? "No active review"
        case "get_undo_status", "undo_status": result = String(describing: try await cards.undoStatus())
        default: throw AgentToolError.invalid("Unknown read operation")
        }
        try checkProfile()
        // Results are untrusted source material, never system instructions.
        return "<untrusted_collection_data>\n\(String(result.prefix(5000)))\n</untrusted_collection_data>"
    }
    private static func json(_ value: JSONSchemaValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func snapshot(_ args: AssistantToolArguments, prepare: Bool) async throws -> String {
        try checkProfile()
        guard ReviewSessionActivity.shared.beginExternalRead() else { throw CancellationError() }
        defer { ReviewSessionActivity.shared.endRead() }
        var parts: [String] = [profile.id, args.action]
        var items: [AssistantChangeItem] = []
        if ["edit_note", "delete_notes", "set_tags"].contains(args.action) {
            guard let ids = args.ids, !ids.isEmpty, ids.count <= 50 else { throw AgentToolError.invalid("Select 1–50 explicit note IDs") }
            for id in ids {
                guard let note = try await notes.fetch(NoteID(id)) else { throw AgentToolError.invalid("Note \(id) no longer exists") }
                let siblings = try await cards.fetchByNote(NoteID(id))
                parts += [String(describing: note), String(describing: siblings)]
                if args.action == "edit_note" {
                    guard ids.count == 1, let fields = args.fields else { throw AgentToolError.invalid("Editing needs one note and all positional fields") }
                    let old = note.flds.components(separatedBy: "\u{1f}")
                    guard old.count == fields.count else { throw AgentToolError.invalid("Field count mismatch") }
                    items += zip(old, fields).enumerated().map { AssistantChangeItem(id: Int64($0.offset), title: "Field \($0.offset + 1)", before: $0.element.0, after: $0.element.1) }
                } else {
                    items.append(AssistantChangeItem(id: id, title: CardText.plainText(note.sfld), before: "\(note.flds)\nTags: \(note.tags)\n\(siblings.count) sibling cards", after: args.action == "delete_notes" ? "Delete note and ALL sibling cards" : (args.tags ?? []).joined(separator: " ")))
                }
            }
        } else if args.action == "add_note" {
            guard args.value == nil else { throw AgentToolError.invalid("add_note uses fieldContents for all question/answer content. The value parameter is only for card flags/dates.") }
            guard let type = args.notetypeID, let deck = args.deckID, let fields = args.fields,
                  let destination = try await decks.fetchAll().first(where: { $0.id.rawValue == deck }) else { throw AgentToolError.invalid("Choose an existing deck and notetype") }
            let template = try await notetypes.get(NotetypeID(type))
            guard template.fields.count == fields.count else { throw AgentToolError.invalid("All positional fields required") }
            parts += [String(describing: template), String(describing: destination)]
            items = fields.enumerated().map { AssistantChangeItem(id: Int64($0.offset), title: template.fields[$0.offset].name, before: "", after: $0.element) }
            if prepare { pendingConsequence = "Create a note in \(destination.name), using \(template.name). Its templates determine the cards created." }
        } else if ["suspend_cards", "restore_cards", "bury_cards", "flag_cards", "set_due", "move_cards", "forget_cards"].contains(args.action) {
            guard let ids = args.ids, !ids.isEmpty, ids.count <= 50 else { throw AgentToolError.invalid("Select 1–50 explicit card IDs") }
            for id in ids {
                let card = try await cards.getCard(CardID(id)); parts.append(String(describing: card))
                items.append(AssistantChangeItem(id: id, title: "Card \(id)", before: String(describing: card), after: "\(args.action) \(args.value ?? "") \(args.deckID.map(String.init) ?? "")"))
            }
            if args.action == "move_cards" {
                guard let deck = args.deckID, let destination = try await decks.fetchAll().first(where: { $0.id.rawValue == deck }) else { throw AgentToolError.invalid("Destination deck missing") }
                parts.append(String(describing: destination))
            }
        } else if ["create_deck", "rename_deck"].contains(args.action) {
            let existing = try await decks.fetchAll(); parts.append(String(describing: existing))
            guard let name = args.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentToolError.invalid("Deck name required") }
            let old = existing.first { $0.id.rawValue == args.deckID }
            if args.action == "rename_deck", old == nil { throw AgentToolError.invalid("Deck does not exist") }
            items = [.init(id: args.deckID ?? 0, title: "Deck", before: old?.name ?? "New deck", after: name)]
        } else if ["update_template", "rename_notetype", "clone_notetype"].contains(args.action) {
            guard let id = args.notetypeID else { throw AgentToolError.invalid("Notetype ID required") }
            let type = try await notetypes.get(NotetypeID(id)); parts.append(String(describing: type))
            if args.action == "update_template" {
                guard let ordinal = args.ids?.first, type.templates.indices.contains(Int(ordinal)), let fields = args.fields, fields.count == 3 else { throw AgentToolError.invalid("Provide template ordinal and three fields: front, back, CSS") }
                let template = type.templates[Int(ordinal)]
                let old = [template.config.qFormat, template.config.aFormat, type.config.css]
                items = zip(old, fields).enumerated().map { .init(id: Int64($0.offset), title: ["Front template", "Back template", "Notetype CSS"][$0.offset], before: $0.element.0, after: $0.element.1) }
            } else {
                guard let name = args.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentToolError.invalid("Notetype name required") }
                items = [.init(id: id, title: type.name, before: String(describing: type), after: args.action + ": " + name)]
            }
            if prepare { pendingConsequence = "Template changes affect every card using this notetype. Review the complete front, back and shared CSS before applying." }
        } else if ["sync", "import_file", "export_collection"].contains(args.action) {
            items = [.init(id: 0, title: profile.displayName, before: "Current profile", after: "Open the existing \(args.action.replacingOccurrences(of: "_", with: " ")) workflow")]
            if prepare { pendingConsequence = "Continue in Ijuka's existing workflow. Import/export keeps its normal file and scope review; sync keeps its existing conflict handling. This approval opens the workflow and does not claim its completion." }
        } else if args.action == "undo" || args.action == "redo" {
            let status = try await cards.undoStatus(); parts.append(String(describing: status))
            items = [.init(id: 0, title: args.action.capitalized, before: String(describing: status), after: "Apply \(args.action) to the collection's most recent operation")]
        } else { throw AgentToolError.invalid("This operation needs its dedicated app workflow; no change was made") }
        if prepare {
            pendingItems = items
            if !["add_note", "update_template", "rename_notetype", "clone_notetype", "sync", "import_file", "export_collection"].contains(args.action) { pendingConsequence = args.action == "delete_notes" ? "Deleting a note deletes every sibling card and its scheduling history." : "Apply only the selected changes. Targets will be checked again before saving." }
        }
        try checkProfile(); return parts.joined(separator: "\n")
    }
    func change(_ requested: AssistantToolArguments) async throws -> String {
        guard let approved, approved.arguments.action == requested.action else { throw AgentToolError.invalid("No reviewed change") }
        self.approved = nil // single-use, including failures
        try checkProfile()
        guard !ReviewSessionCoordinator.shared.hasActiveSession else { throw AgentToolError.invalid("Close the active review before modifying the collection") }
        guard ReviewSessionActivity.shared.beginMutation() else { throw AgentToolError.invalid("Collection is busy or switching") }
        defer { ReviewSessionActivity.shared.endMutation() }
        // Compare the ORIGINAL requested set, even if the user selected a subset.
        guard try await snapshot(requested, prepare: false) == approved.snapshot else { throw AgentToolError.invalid("Targets changed since review. Propose the change again.") }
        try checkProfile()
        guard let activation = backend.collectionActivationID else { throw AgentToolError.invalid("No collection is open") }
        let result = try await AssistantCollectionMutator.apply(original: requested, approved: approved.arguments, expected: approved.snapshot, profileID: profile.id, activation: activation)
        store.apply(CollectionChanges(card: true, note: true, studyQueues: true))
        recordCommit(approved.arguments, outcome: result.outcome, targets: result.targets)
        // Do not check cancellation AFTER an RPC committed: its actual result
        // must be reported and journaled even if the surface closed meanwhile.
        var payload: [String: JSONSchemaValue] = ["outcome": .string(result.outcome), "targetIDs": .array(result.targets.map { .integer($0) })]
        if let fields = result.appliedFields { payload["appliedFields"] = .array(fields.map(JSONSchemaValue.string)) }
        return try Self.json(.object(payload))
    }

    func navigate(_ args: AssistantToolArguments) async throws -> String {
        try checkProfile()
        if ["sync", "import_file", "export_collection"].contains(args.action) {
            let encoded = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
            let decision = await approve(ToolCall(id: UUID().uuidString, toolName: "change_collection", arguments: encoded))
            guard decision == .approved, let approved, approved.arguments == args else { throw AgentToolError.invalid("Workflow declined") }
            self.approved = nil
            try checkProfile()
        }
        switch args.action {
        case "section": openRoute(.section(args.value ?? "library"))
        case "settings": openRoute(.settings)
        case "browse": openRoute(.browse(args.query ?? ""))
        case "review": guard let id = args.deckID else { throw AgentToolError.invalid("Deck ID required") }; openRoute(.review(id))
        case "sync": openRoute(.sync)
        case "import_file": openRoute(.importFile)
        case "export_collection": openRoute(.exportCollection)
        default: throw AgentToolError.invalid("Unknown app destination")
        }
        return "Opened the requested app surface. Its workflow reports the actual result."
    }

}

enum AgentToolError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { reason } else { nil } }
}

struct AssistantCollectionTool: ToolExecutor {
    let host: AssistantToolHost
    let writes: Bool
    var requiresApproval: Bool { writes }
    var definition: ToolDefinition {
        let actions = writes
            ? ["add_note", "edit_note", "delete_notes", "set_tags", "suspend_cards", "restore_cards", "bury_cards", "flag_cards", "set_due", "move_cards", "forget_cards", "create_deck", "rename_deck", "update_template", "rename_notetype", "clone_notetype", "undo", "redo"]
            : ["capabilities", "list_decks", "get_study_overview", "list_notetypes", "get_notetype", "search_notes", "get_note", "get_card", "get_deck_config", "get_review_context", "get_undo_status", "retrieve"]
        let string: JSONSchemaValue = .object(["type": .string("string")])
        let integer: JSONSchemaValue = .object(["type": .string("integer")])
        var properties: [String: JSONSchemaValue] = [
            "action": .object(["type": .string("string"), "enum": .array(actions.map(JSONSchemaValue.string))]),
            "query": .object(["type": .string("string"), "description": .string("For search_notes: Anki query syntax. For retrieve: a natural-language question.")]),
            "deckID": .object(["type": .string("integer"), "description": .string("Actual deck ID from list_decks. Required by get_deck_config and add_note.")]),
            "notetypeID": .object(["type": .string("integer"), "description": .string("Actual notetype ID from list_notetypes. Required by get_notetype and add_note.")]),
            "ids": .object(["type": .string("array"), "items": integer, "description": .string("Explicit note or card IDs from prior reads. get_note/get_card require one ID.")]),
        ]
        if writes {
            properties["name"] = .object(["type": .string("string"), "description": .string("New name for create_deck, rename_deck, rename_notetype or clone_notetype.")])
            properties["value"] = .object(["type": .string("string"), "description": .string("Only flag_cards (0–7) or set_due (date expression). Never put note content here; use fieldContents.")])
            properties["fieldContents"] = .object(["type": .string("array"), "items": string, "description": .string("The actual text to save in each note field, in schema order. For Basic: [question text, answer text]. Use the user's requested words, never field names like Front/Back. update_template uses [front HTML, back HTML, CSS].")])
            properties["tags"] = .object(["type": .string("array"), "items": string])
        }
        return ToolDefinition(name: writes ? "change_collection" : "read_collection", description: writes ? "Propose a reviewed collection change. To create a flashcard/note use add_note with deckID, notetypeID and fieldContents containing the actual question/answer. create_deck creates an empty DECK only. Read actual IDs first; never invent them. Every write requires user review." : "Read collection data. list_decks returns deck names/IDs. list_notetypes returns notetype names/IDs. get_notetype requires notetypeID and returns ordered fields/templates. To add a note, first list_decks, list_notetypes, then get_notetype. search_notes accepts Anki query syntax; retrieve finds relevant notes/books/media from natural language.", parameters: .object([
            "type": .string("object"), "required": .array([.string("action")]),
            "additionalProperties": .bool(false), "properties": .object(properties)
        ]))
    }
    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        let args = try JSONDecoder().decode(AssistantToolArguments.self, from: JSONEncoder().encode(arguments))
        let result = try await (writes ? host.change(args) : host.read(args))
        return ToolResult(callId: "", content: result)
    }
}

struct AssistantNavigationTool: ToolExecutor {
    let host: AssistantToolHost
    var definition: ToolDefinition {
        ToolDefinition(name: "open_app", description: "Navigate within Ijuka. Section value is library, read, study, stats or browse. Sync/import/export require review and use existing app workflows; never claim these workflows have finished just because they opened.", parameters: .object([
            "type": .string("object"), "required": .array([.string("action")]),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array(["section", "settings", "browse", "review", "sync", "import_file", "export_collection"].map(JSONSchemaValue.string))]),
                "value": .object(["type": .string("string")]), "query": .object(["type": .string("string")]), "deckID": .object(["type": .string("integer")]),
            ])
        ]))
    }
    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        let args = try JSONDecoder().decode(AssistantToolArguments.self, from: JSONEncoder().encode(arguments))
        return try await ToolResult(callId: "", content: host.navigate(args))
    }
}
