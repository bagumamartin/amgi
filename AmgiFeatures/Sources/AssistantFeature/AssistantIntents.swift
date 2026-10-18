import AmgiAppCore
import AmgiEmbeddings
import AmgiAppShared
import AmgiCardWeb
import AmgiReviewCore
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiProtoBridge
import AnkiServices
import Dependencies
import Foundation
import FoundationModels

/// One line of what the assistant actually did, written by Swift from the
/// real result — never by the model. The chat shows these verbatim, so a
/// reply can't claim a save that didn't happen.
struct AssistantStep: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case running, done, failed, declined }
    var id = UUID()
    var icon: String
    var text: String
    var state: State
}

/// Cards the model proposed, held for the user to edit before anything is
/// written.
struct FlashcardDraft: Identifiable, Sendable {
    struct Card: Identifiable, Hashable, Sendable {
        var id = UUID()
        var front: String
        var back: String
        var included = true
    }
    struct Deck: Identifiable, Hashable, Sendable {
        let id: Int64
        let name: String
    }
    let id = UUID()
    var cards: [Card]
    var deckID: Int64
    let decks: [Deck]
    let notetypeName: String
    var includedCount: Int { cards.filter { $0.included && !$0.front.isBlank }.count }
}

/// Field-level corrections to the note the chat is about, held for review.
struct NoteFixDraft: Identifiable, Sendable {
    struct Field: Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let before: String
        var after: String
        var included = true
    }
    let id = UUID()
    let noteID: Int64
    var fields: [Field]
    var changedCount: Int { fields.filter { $0.included && $0.after != $0.before }.count }
}

/// Everything the model is allowed to do, as a handful of task-shaped
/// intents. The model picks an intent and supplies words; Swift resolves
/// decks, note types and fields, asks the user, writes, and reports.
///
/// The previous design handed a ~3B on-device model raw IDs to carry across a
/// four-call chain (list decks → list note types → read fields → add). It
/// misfired on greetings and reported saves that had been rejected.
@MainActor
final class AssistantToolbox {
    let profile: ProfileContext
    /// What the chat is about. The first card-like context is the one
    /// "fix this card" edits; the first deck is where new cards go.
    var contexts: [AssistantContext]
    var noteID: Int64? { contexts.first { $0.type == .note || $0.type == .review }?.noteID }
    var deckID: Int64? { contexts.first { $0.type == .deck }?.deckID ?? contexts.lazy.compactMap(\.deckID).first }
    /// Inserts or replaces a step (matched by id) on the turn in progress.
    var report: (AssistantStep) -> Void = { _ in }
    /// Presents the draft and resumes with the user's edits, or `nil` when
    /// they decline.
    var review: (FlashcardDraft) async -> FlashcardDraft? = { _ in nil }
    var reviewFix: (NoteFixDraft) async -> NoteFixDraft? = { _ in nil }
    /// Called after the chat's note was edited, so a screen showing it
    /// (Review) can re-render.
    var noteSaved: () -> Void = {}
    var open: (AssistantRoute) -> Void = { _ in }
    /// Sources found during the turn in progress.
    var sources: [AssistantSource] = []
    /// Set when the turn in progress saved something — the head celebrates.
    var savedCount = 0
    /// The user said no to cards in this turn. Small models re-propose after
    /// a refusal; one "no" per turn is final.
    private var declinedThisTurn = false

    @Dependency(\.deckClient) private var decks
    @Dependency(\.noteClient) private var notes
    @Dependency(\.notetypesClient) private var notetypes
    @Dependency(\.collectionStore) private var store

    init(profile: ProfileContext, contexts: [AssistantContext]) {
        self.profile = profile
        self.contexts = contexts
    }

    func beginTurn() {
        sources = []
        savedCount = 0
        declinedThisTurn = false
    }

    // MARK: Study overview

    func studyOverview(focus: String?) async -> String {
        var step = AssistantStep(icon: "calendar", text: L10n.text("Checking what's due"), state: .running)
        report(step)
        do {
            try checkProfile()
            let tree = try await decks.fetchTree()
            var nodes = tree
            if let focus, let match = Self.flatten(tree).first(where: { Self.matches($0.fullName, focus) }) {
                nodes = [match]
            }
            let lines = nodes.prefix(12).map { node in
                "\(node.fullName): \(node.counts.newCount) new, \(node.counts.learnCount) learning, \(node.counts.reviewCount) to review"
            }
            let due = nodes.reduce(0) { $0 + $1.counts.newCount + $1.counts.learnCount + $1.counts.reviewCount }
            step.text = due == 0 ? L10n.text("Nothing due right now") : L10n.text("\(due) cards due today")
            step.state = .done
            report(step)
            return lines.isEmpty ? "The collection has no decks yet." : lines.joined(separator: "\n")
        } catch {
            return fail(&step, error)
        }
    }

    // MARK: Find notes

    func findNotes(_ question: String) async -> String {
        var step = AssistantStep(icon: "magnifyingglass", text: L10n.text("Searching your notes"), state: .running)
        report(step)
        do {
            try checkProfile()
            guard ReviewSessionActivity.shared.beginExternalRead() else { throw CancellationError() }
            defer { ReviewSessionActivity.shared.endRead() }
            let hits = try await CollectionRetrievalCoordinator.shared.search(question, limit: 5)
            let found = hits.map { hit in
                AssistantSource(
                    id: hit.segment.id, sourceID: hit.segment.sourceID, title: hit.segment.title,
                    excerpt: String(hit.segment.text.prefix(4000)), anchor: hit.segment.anchor,
                    url: hit.segment.sourceURL, modality: hit.segment.modality.rawValue
                )
            }
            sources.append(contentsOf: found)
            step.text = found.isEmpty ? L10n.text("No matching notes") : L10n.text("Found \(found.count) related notes")
            step.state = .done
            report(step)
            guard !found.isEmpty else { return "NO_RESULTS: nothing in the collection matches. Say so plainly." }
            return found.enumerated().map { index, source in
                "[\(index + 1)] \(source.title): \(source.excerpt.prefix(320))"
            }.joined(separator: "\n")
        } catch {
            return fail(&step, error)
        }
    }

    // MARK: Make flashcards

    func makeFlashcards(_ proposed: [(front: String, back: String)], deckHint: String?) async -> String {
        guard !declinedThisTurn else {
            return "DECLINED: the user already declined cards in this message. Do not propose cards again; acknowledge in one short sentence."
        }
        var step = AssistantStep(icon: "rectangle.stack.badge.plus", text: L10n.text("Drafting \(proposed.count) cards"), state: .running)
        report(step)
        do {
            try checkProfile()
            let cards = proposed
                .map { FlashcardDraft.Card(front: $0.front.trimmed, back: $0.back.trimmed) }
                .filter { !$0.front.isBlank }
            guard !cards.isEmpty else { throw AgentToolError.invalid(L10n.text("No card text was given")) }
            let allDecks = try await decks.fetchAll()
                .map { FlashcardDraft.Deck(id: $0.id.rawValue, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !allDecks.isEmpty else { throw AgentToolError.invalid(L10n.text("Create a deck first")) }
            let deckID = resolveDeck(hint: deckHint, in: allDecks)
            let (notetypeID, notetypeName, fieldCount) = try await basicNotetype()

            step.text = L10n.text("Waiting for you to review \(cards.count) cards")
            report(step)
            let draft = FlashcardDraft(cards: cards, deckID: deckID, decks: allDecks, notetypeName: notetypeName)
            guard let approved = await review(draft) else {
                step.text = L10n.text("You chose not to add these cards")
                step.state = .declined
                report(step)
                declinedThisTurn = true
                return "DECLINED: the user chose not to add the cards. Nothing was saved. Acknowledge in one short sentence; do not repeat the cards or propose new ones."
            }
            let keep = approved.cards.filter { $0.included && !$0.front.isBlank }
            guard !keep.isEmpty else {
                step.text = L10n.text("No cards were selected")
                step.state = .declined
                report(step)
                declinedThisTurn = true
                return "DECLINED: the user removed every card. Nothing was saved. Acknowledge in one short sentence."
            }
            try checkProfile()
            guard !ReviewSessionCoordinator.shared.hasActiveSession else {
                throw AgentToolError.invalid(L10n.text("Finish or close the review first, then try again"))
            }
            guard ReviewSessionActivity.shared.beginMutation() else {
                throw AgentToolError.invalid(L10n.text("The collection is busy. Try again in a moment"))
            }
            defer { ReviewSessionActivity.shared.endMutation() }
            let saved = try await Self.addNotes(
                keep.map { [$0.front, $0.back] }, notetypeID: notetypeID, fieldCount: fieldCount,
                deckID: approved.deckID
            )
            store.apply(CollectionChanges(card: true, note: true, studyQueues: true))
            savedCount += saved
            let deckName = allDecks.first { $0.id == approved.deckID }?.name ?? ""
            step.text = L10n.text("Added \(saved) cards to \(deckName)")
            step.state = .done
            report(step)
            return "SAVED: \(saved) cards were added to the deck \"\(deckName)\". Confirm in one short sentence."
        } catch {
            return fail(&step, error)
        }
    }

    // MARK: Fix this card

    // MARK: Context

    /// Fills in what a context only names: a card's fields and a readable
    /// title, a deck's workload, the collection's decks. Quiet — no steps.
    func resolve(_ context: AssistantContext) async -> AssistantContext {
        var resolved = context
        switch context.type {
        case .note, .review:
            guard let id = context.noteID, let note = try? await notes.fetch(NoteID(id)),
                  let type = try? await notetypes.get(note.mid) else { return context }
            let values = note.flds.components(separatedBy: "\u{1f}")
            resolved.reference = zip(type.fields.map(\.name), values)
                .map { "\($0): \(String(CardText.plainText($1).prefix(1200)))" }
                .joined(separator: "\n")
            let front = values.first.map { CardText.plainText($0).trimmed } ?? ""
            if !front.isEmpty {
                resolved.title = String(front.prefix(60)) + (front.count > 60 ? "…" : "")
            }
            let deckName = await deckName(context.deckID ?? 0)
            resolved.subtitle = context.type == .review
                ? (deckName.map { L10n.text("Reviewing in \($0)") } ?? L10n.text("Card in review"))
                : (deckName.map { L10n.text("\(type.name) in \($0)") } ?? type.name)
        case .deck:
            guard let id = context.deckID, let tree = try? await decks.fetchTree(),
                  let node = Self.flatten(tree).first(where: { $0.id.rawValue == id }) else { return context }
            let lines = Self.flatten([node]).prefix(20).map { "\($0.fullName): \($0.counts.newCount) new, \($0.counts.learnCount) learning, \($0.counts.reviewCount) to review" }
            resolved.reference = "Deck \(node.fullName). Due today:\n" + lines.joined(separator: "\n")
        case .collection:
            guard let tree = try? await decks.fetchTree() else { return context }
            let all = Self.flatten(tree)
            let lines = all.prefix(30).map { "\($0.fullName): \($0.counts.newCount) new, \($0.counts.learnCount) learning, \($0.counts.reviewCount) to review" }
            resolved.reference = "The user's flashcard collection has \(all.count) decks. Due today:\n" + lines.joined(separator: "\n")
            resolved.subtitle = all.count == 1 ? L10n.text("1 deck") : L10n.text("\(all.count) decks")
        case .book, .chapter, .page, .passage:
            break
        }
        return resolved
    }

    /// Every deck, for the context picker.
    func allDecks() async -> [AssistantContext] {
        let all = (try? await decks.fetchAll()) ?? []
        return all.map { AssistantContext.deck(id: $0.id.rawValue, name: $0.name) }
            .sorted { $0.subtitle + $0.title < $1.subtitle + $1.title }
    }

    private func deckName(_ id: Int64) async -> String? {
        guard id != 0 else { return nil }
        return try? await decks.fetchAll().first { $0.id.rawValue == id }?.name
    }

    func fixThisCard(_ fixes: [(field: String, text: String)]) async -> String {
        guard !declinedThisTurn else {
            return "DECLINED: the user already declined a change in this message. Acknowledge in one short sentence."
        }
        var step = AssistantStep(icon: "pencil", text: L10n.text("Preparing a correction"), state: .running)
        report(step)
        do {
            try checkProfile()
            guard let id = noteID else {
                throw AgentToolError.invalid(L10n.text("Open the card you want to fix, then ask again"))
            }
            guard let note = try await notes.fetch(NoteID(id)) else {
                throw AgentToolError.invalid(L10n.text("This card no longer exists"))
            }
            let names = try await notetypes.get(note.mid).fields.map(\.name)
            let current = note.flds.components(separatedBy: "\u{1f}")
            var fields = names.enumerated().map { index, name in
                let before = index < current.count ? current[index] : ""
                return NoteFixDraft.Field(id: index, name: name, before: before, after: before)
            }
            for (position, fix) in fixes.enumerated() {
                guard let index = Self.fieldIndex(for: fix.field, position: position, in: names) else { continue }
                // The model sees plain text. Echoing a field back unchanged
                // must not strip its formatting.
                let text = fix.text.trimmed
                if text != CardText.plainText(fields[index].before).trimmed { fields[index].after = text }
            }
            let changed = fields.filter { $0.after != $0.before && !$0.after.isBlank }
            guard !changed.isEmpty else {
                step.text = L10n.text("The suggested text matched the card")
                step.state = .failed
                report(step)
                return "UNCHANGED: the text you sent is what the card already says. Call fixThisCard again with the NEW text the user asked for, or ask the user what to change."
            }

            step.text = L10n.text("Waiting for you to review the correction")
            report(step)
            guard let approved = await reviewFix(NoteFixDraft(noteID: id, fields: changed)) else {
                step.text = L10n.text("You kept the card as it was")
                step.state = .declined
                report(step)
                declinedThisTurn = true
                return "DECLINED: the user kept the card unchanged. Nothing was saved. Acknowledge in one short sentence."
            }
            var values = names.indices.map { $0 < current.count ? current[$0] : "" }
            for field in approved.fields where field.included { values[field.id] = field.after }
            guard approved.changedCount > 0 else {
                step.text = L10n.text("No changes were selected")
                step.state = .declined
                report(step)
                declinedThisTurn = true
                return "DECLINED: the user deselected every change. Nothing was saved."
            }
            try checkProfile()
            guard ReviewSessionActivity.shared.beginMutation() else {
                throw AgentToolError.invalid(L10n.text("The collection is busy. Try again in a moment"))
            }
            defer { ReviewSessionActivity.shared.endMutation() }
            try await Self.saveFields(values, noteID: id)
            store.apply(CollectionChanges(card: true, note: true, studyQueues: false))
            savedCount += 1
            noteSaved()
            let count = approved.changedCount
            step.text = count == 1 ? L10n.text("Updated 1 field") : L10n.text("Updated \(count) fields")
            step.state = .done
            report(step)
            return "SAVED: the card was updated. Confirm in one short sentence."
        } catch {
            return fail(&step, error)
        }
    }

    /// Matches the model's field label to a real field: by name, then by the
    /// usual question/answer words, then by order.
    private static func fieldIndex(for label: String, position: Int, in names: [String]) -> Int? {
        let wanted = label.trimmed.lowercased()
        if let exact = names.firstIndex(where: { $0.lowercased() == wanted }) { return exact }
        if let partial = names.firstIndex(where: { $0.lowercased().contains(wanted) || wanted.contains($0.lowercased()) }), !wanted.isEmpty {
            return partial
        }
        if ["front", "question", "prompt", "term"].contains(wanted) { return names.isEmpty ? nil : 0 }
        if ["back", "answer", "definition"].contains(wanted) { return names.count > 1 ? 1 : nil }
        return position < names.count ? position : nil
    }

    @concurrent private static func saveFields(_ values: [String], noteID: Int64) async throws {
        @Dependency(\.ankiBackend) var backend
        @Dependency(\.notesService) var notes
        try backend.withLifecycleAccess {
            var note = try notes.getNote(NoteID(noteID))
            note.flds = values.joined(separator: "\u{1f}")
            try notes.saveNote(note)
        }
    }

    // MARK: Open

    func open(destination: String, target: String?) async -> String {
        do {
            try checkProfile()
            switch destination {
            case "review":
                let all = try await decks.fetchAll().map { FlashcardDraft.Deck(id: $0.id.rawValue, name: $0.name) }
                let id = resolveDeck(hint: target, in: all)
                report(AssistantStep(icon: "play.rectangle", text: L10n.text("Opening review"), state: .done))
                open(.review(id))
            case "browse":
                report(AssistantStep(icon: "rectangle.and.text.magnifyingglass", text: L10n.text("Opening Browse"), state: .done))
                open(.browse(target ?? ""))
            case "stats":
                report(AssistantStep(icon: "chart.bar", text: L10n.text("Opening Stats"), state: .done))
                open(.section("stats"))
            default:
                report(AssistantStep(icon: "books.vertical", text: L10n.text("Opening Library"), state: .done))
                open(.section("library"))
            }
            return "OPENED"
        } catch {
            var step = AssistantStep(icon: "arrow.up.forward.app", text: "", state: .failed)
            return fail(&step, error)
        }
    }

    // MARK: Helpers

    private func fail(_ step: inout AssistantStep, _ error: any Error) -> String {
        let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        step.text = reason
        step.state = .failed
        report(step)
        return "FAILED: \(reason). Nothing was changed. Tell the user briefly; do not claim success."
    }

    private func checkProfile() throws {
        guard profile.isCurrent(AccountStore.shared.selectedContext) else { throw AssistantError.profileChanged }
        try Task.checkCancellation()
    }

    /// The deck the user named; else the deck they opened the assistant
    /// from; else the first non-default deck. The review sheet lets them
    /// change it, so a near miss costs a tap, not a wrong save.
    private func resolveDeck(hint: String?, in all: [FlashcardDraft.Deck]) -> Int64 {
        if let hint = hint?.trimmed, !hint.isEmpty {
            if let exact = all.first(where: { $0.name.caseInsensitiveCompare(hint) == .orderedSame }) { return exact.id }
            if let close = all.first(where: { Self.matches($0.name, hint) }) { return close.id }
        }
        if let scoped = deckID, all.contains(where: { $0.id == scoped }) { return scoped }
        return (all.first { $0.name != "Default" } ?? all[0]).id
    }

    private static func matches(_ name: String, _ hint: String) -> Bool {
        let leaf = name.components(separatedBy: "::").last ?? name
        return leaf.localizedCaseInsensitiveContains(hint) || hint.localizedCaseInsensitiveContains(leaf)
    }

    private static func flatten(_ nodes: [DeckTreeNode]) -> [DeckTreeNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    /// "Basic" when it exists, otherwise the first note type with at least a
    /// front and a back.
    private func basicNotetype() async throws -> (NotetypeID, String, Int) {
        let types = try await notetypes.listAll()
        let ordered = types.filter { $0.name == "Basic" } + types.filter { $0.name != "Basic" }
        for entry in ordered {
            let type = try await notetypes.get(entry.id)
            if type.fields.count >= 2 { return (type.id, type.name, type.fields.count) }
        }
        throw AgentToolError.invalid(L10n.text("No note type with a front and back exists"))
    }

    @concurrent private static func addNotes(_ cards: [[String]], notetypeID: NotetypeID, fieldCount: Int, deckID: Int64) async throws -> Int {
        @Dependency(\.ankiBackend) var backend
        @Dependency(\.notesService) var notes
        return try backend.withLifecycleAccess {
            var saved = 0
            for fields in cards {
                var template = try notes.newNote(notetypeID)
                template.fields = fields + Array(repeating: "", count: max(0, fieldCount - fields.count))
                _ = try backend.invoke(.addNoteWithResult(template: template, deckId: DeckID(deckID)))
                saved += 1
            }
            return saved
        }
    }
}

enum AgentToolError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { reason } else { nil } }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}

// MARK: - Foundation Models intents

struct StudyOverviewIntent: Tool {
    let toolbox: AssistantToolbox
    let name = "studyOverview"
    let description = "Cards due today in each deck. Use when the user asks what to study, how much is due, or about their workload."

    @Generable struct Arguments {
        @Guide(description: "A deck the user named, if any")
        var deck: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await toolbox.studyOverview(focus: arguments.deck)
    }
}

struct FindNotesIntent: Tool {
    let toolbox: AssistantToolbox
    let name = "findNotes"
    let description = "Search the user's own flashcards, notes and books. Use when the answer should come from what they have studied."

    @Generable struct Arguments {
        @Guide(description: "What to look for, in the user's words")
        var question: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await toolbox.findNotes(arguments.question)
    }
}

struct MakeFlashcardsIntent: Tool {
    let toolbox: AssistantToolbox
    let name = "makeFlashcards"
    let description = "Create flashcards. Use only when the user asks to make, add or create cards. The user reviews them before anything is saved."

    @Generable struct Card {
        @Guide(description: "The question or prompt side")
        var front: String
        @Guide(description: "The answer side")
        var back: String
    }

    @Generable struct Arguments {
        @Guide(description: "The flashcards to create", .maximumCount(12))
        var cards: [Card]
        @Guide(description: "The deck the user named, if any")
        var deck: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await toolbox.makeFlashcards(arguments.cards.map { ($0.front, $0.back) }, deckHint: arguments.deck)
    }
}

struct FixThisCardIntent: Tool {
    let toolbox: AssistantToolbox
    let name = "fixThisCard"
    let description = "Correct or improve the card the user is looking at. Use only when they say it is wrong, has a typo, is unclear, or ask to change it. The user reviews the change before it is saved."

    @Generable struct FieldFix {
        @Guide(description: "The field to change, using a field name from <screen>, for example Front or Back")
        var field: String
        @Guide(description: "The NEW text the field should contain after the fix. If the user gave the wording, use it exactly. Never the current text.")
        var text: String
    }

    @Generable struct Arguments {
        @Guide(description: "Only the fields that change", .maximumCount(6))
        var fixes: [FieldFix]
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await toolbox.fixThisCard(arguments.fixes.map { ($0.field, $0.text) })
    }
}

struct OpenScreenIntent: Tool {
    let toolbox: AssistantToolbox
    let name = "openScreen"
    let description = "Open part of the app: start reviewing a deck, browse cards, see stats, or go to the library. Use only when the user asks to go somewhere or start studying."

    @Generable struct Arguments {
        @Guide(description: "Where to go", .anyOf(["review", "browse", "stats", "library"]))
        var destination: String
        @Guide(description: "Deck name for review, or search words for browse")
        var target: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await toolbox.open(destination: arguments.destination, target: arguments.target)
    }
}
