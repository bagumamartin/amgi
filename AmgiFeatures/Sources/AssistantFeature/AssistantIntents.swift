import AmgiAppCore
import AmgiEmbeddings
import AmgiAppShared
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
    var scope: AssistantContext
    /// Inserts or replaces a step (matched by id) on the turn in progress.
    var report: (AssistantStep) -> Void = { _ in }
    /// Presents the draft and resumes with the user's edits, or `nil` when
    /// they decline.
    var review: (FlashcardDraft) async -> FlashcardDraft? = { _ in nil }
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

    init(profile: ProfileContext, scope: AssistantContext) {
        self.profile = profile
        self.scope = scope
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
        if let scoped = scope.deckID, all.contains(where: { $0.id == scoped }) { return scoped }
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
