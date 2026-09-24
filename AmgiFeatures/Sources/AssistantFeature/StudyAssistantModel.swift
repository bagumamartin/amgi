import AmgiAppCore
import AmgiAppShared
import AmgiCardWeb
import AmgiReviewCore
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
public import Observation

@MainActor
@Observable
public final class StudyAssistantModel {
    public private(set) var overview: StudyOverview = .empty
    public private(set) var messages: [AssistantMessage] = []
    public private(set) var isThinking = false
    public private(set) var errorMessage: String?
    public var draft = ""
    public private(set) var composerPlaceholder = "Ask about your collection"

    public var availability: AssistantModelAvailability {
        FoundationModelService.availability
    }

    public init() {}

    public func prepare(initialPrompt: String? = nil) async {
        let initialProfile = AccountStore.shared.selectedContext
        do {
            _ = try await loadOverview()
        } catch {
            guard initialProfile.isCurrent(AccountStore.shared.selectedContext) else { return }
            errorMessage = userFacingMessage(for: error)
        }
        guard initialProfile.isCurrent(AccountStore.shared.selectedContext) else { return }
        if messages.isEmpty {
            messages.append(
                AssistantMessage(
                    role: .assistant,
                    text: welcomeText
                )
            )
        }
        if let initialPrompt,
           !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await ask(initialPrompt)
        }
    }

    public func perform(_ suggestion: AssistantSuggestion) async {
        switch suggestion.action {
        case .planStudy:
            await makeStudyPlan()
        case .explainCurrentCard:
            await explainCurrentCard()
        case .askCollection:
            beginCollectionQuestion()
        }
    }

    public func beginCollectionQuestion() {
        composerPlaceholder = "What should I look for in your notes?"
        draft = ""
    }

    public func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }
        draft = ""
        await ask(prompt)
    }

    public func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(AssistantMessage(role: .user, text: trimmed))
        errorMessage = nil
        isThinking = true
        defer { isThinking = false }

        do {
            let profile = AccountStore.shared.selectedContext
            let result = try await answerCollectionQuestion(trimmed, profile: profile)
            try ensureProfileUnchanged(profile)
            messages.append(
                AssistantMessage(
                    role: .assistant,
                    text: result.text,
                    citations: result.citations
                )
            )
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    public func makeStudyPlan() async {
        guard !isThinking else { return }
        messages.append(AssistantMessage(role: .user, text: "Plan my study for today."))
        errorMessage = nil
        isThinking = true
        defer { isThinking = false }

        do {
            let profile = AccountStore.shared.selectedContext
            let loadedOverview = try await loadOverview()
            let context = studyContext(from: loadedOverview)
            let text: String
            if canGenerate {
                if #available(iOS 26.0, macOS 26.0, *) {
                    do {
                        let generated = try await FoundationModelService.respond(
                            instructions: AssistantPromptBuilder.instructions,
                            prompt: AssistantPromptBuilder.studyPlan(context: context)
                        )
                        text = generated.isEmpty ? deterministicStudyPlan(loadedOverview) : generated
                    } catch {
                        text = deterministicStudyPlan(loadedOverview)
                        errorMessage = "Apple Intelligence could not respond. Showing a deterministic plan instead."
                    }
                } else {
                    text = deterministicStudyPlan(loadedOverview)
                }
            } else {
                text = deterministicStudyPlan(loadedOverview)
            }
            try ensureProfileUnchanged(profile)
            messages.append(AssistantMessage(role: .assistant, text: text))
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    public func explainCurrentCard() async {
        guard !isThinking else { return }
        messages.append(AssistantMessage(role: .user, text: "Explain the card I’m reviewing."))
        errorMessage = nil
        isThinking = true
        defer { isThinking = false }

        let profile = AccountStore.shared.selectedContext
        guard let snapshot = ReviewSessionContext.shared.currentSnapshot(),
              snapshot.profileID == profile.id,
              snapshot.profileSelectionID == profile.selectionID,
              let cardID = snapshot.currentCardId,
              let noteID = snapshot.currentNoteId
        else {
            messages.append(
                AssistantMessage(
                    role: .assistant,
                    text: "Open a card in Review first, then ask again. I only use the live review context while that session is on screen."
                )
            )
            return
        }

        do {
            @Dependency(\.noteClient) var noteClient
            @Dependency(\.cardClient) var cardClient
            let cardEntityID = CardID(cardID)
            let note = try await noteClient.fetch(NoteID(noteID))
            let stats = try? await cardClient.cardStats(cardEntityID)
            let context = currentCardContext(
                snapshot: snapshot,
                cardID: cardID,
                note: note,
                stats: stats
            )
            let text: String
            if canGenerate {
                if #available(iOS 26.0, macOS 26.0, *) {
                    do {
                        let generated = try await FoundationModelService.respond(
                            instructions: AssistantPromptBuilder.instructions,
                            prompt: AssistantPromptBuilder.currentCard(context: context)
                        )
                        text = generated.isEmpty
                            ? "Review the card’s full fields and recent history to identify the source of difficulty."
                            : generated
                    } catch {
                        text = "I couldn’t generate an explanation just now. Review the card again and check whether its wording and answer are unambiguous."
                        errorMessage = "Apple Intelligence could not respond."
                    }
                } else {
                    text = "Open the card’s full fields and review history to identify the source of difficulty."
                }
            } else {
                text = "Check whether the prompt is ambiguous, whether nearby cards are confusable, and whether the answer contains only the minimum cue needed."
            }
            try ensureProfileUnchanged(profile)
            messages.append(AssistantMessage(role: .assistant, text: text))
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    private var canGenerate: Bool {
        AutomationPreferences.foundationModelsEnabled && availability == .ready
    }

    private var welcomeText: String {
        let total = overview.due.total
        if total == 0 {
            return "You’re caught up in \(overview.profileName). Ask me to look across your notes, or choose a prompt below."
        }
        return "\(total) cards are ready in \(overview.profileName). I can explain the live review card, help you plan today, or answer from bounded note results."
    }

    private func loadOverview() async throws -> StudyOverview {
        let context = AccountStore.shared.selectedContext
        @Dependency(\.deckClient) var client
        let tree = try await client.fetchTree()
        let loaded = StudyOverview(
            due: Self.totalDue(in: tree),
            activeDeckCount: tree.count,
            profileName: context.displayName
        )
        try ensureProfileUnchanged(context)
        overview = loaded
        return loaded
    }

    private func answerCollectionQuestion(
        _ question: String,
        profile: ProfileContext
    ) async throws -> AssistantResult {
        @Dependency(\.noteClient) var noteClient
        let searchQuery = String(question.prefix(500))
        let records = try await noteClient.searchAll(searchQuery, 5)
        try ensureProfileUnchanged(profile)
        guard !records.isEmpty else {
            return AssistantResult(
                text: "I couldn’t find a matching note. Try a distinctive phrase, tag, or Anki search term.",
                citations: []
            )
        }

        let contextText = records.prefix(4).map(Self.noteReference).joined(separator: "\n\n")
        let text: String
        if canGenerate {
            if #available(iOS 26.0, macOS 26.0, *) {
                do {
                    let generated = try await FoundationModelService.respond(
                        instructions: AssistantPromptBuilder.instructions,
                        prompt: AssistantPromptBuilder.collectionQuestion(
                            question: question,
                            context: contextText
                        )
                    )
                    text = generated.isEmpty ? Self.deterministicCollectionAnswer(records) : generated
                } catch {
                    text = Self.deterministicCollectionAnswer(records)
                    errorMessage = "Apple Intelligence could not respond. Showing matching notes instead."
                }
            } else {
                text = Self.deterministicCollectionAnswer(records)
            }
        } else {
            text = Self.deterministicCollectionAnswer(records)
        }
        return AssistantResult(
            text: text,
            citations: records.prefix(4).map {
                AssistantCitation(
                    id: $0.id.rawValue,
                    title: String(CardText.plainText($0.sfld).prefix(160)),
                    profile: profile
                )
            }
        )
    }

    private func studyContext(from overview: StudyOverview) -> String {
        let due = overview.due
        return """
        Profile: \(overview.profileName)
        Due now: \(due.total) total — \(due.newCount) new, \(due.learnCount) learning, \(due.reviewCount) review
        Top-level decks: \(overview.activeDeckCount)
        """
    }

    private func deterministicStudyPlan(_ overview: StudyOverview) -> String {
        let due = overview.due
        guard due.total > 0 else { return "You’re caught up. Use the time for a short optional review or card cleanup." }
        let start = min(20, max(5, due.total / 4))
        if due.learnCount > due.reviewCount {
            return "Start with \(start) cards and finish the learning queue first. It is the largest actionable part of today’s workload (\(due.learnCount) learning, \(due.reviewCount) review). Keep the session short enough to finish, then reassess."
        }
        return "Start with \(start) cards, prioritize mature cards that are due for review, and stop while recall is still reliable. You have \(due.newCount) new and \(due.reviewCount) review cards waiting."
    }

    private func currentCardContext(
        snapshot: ReviewSessionSnapshot,
        cardID: Int64,
        note: NoteRecord?,
        stats: CardStatsInfo?
    ) -> String {
        let fields: String
        if let note {
            let values = note.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            fields = values.enumerated().map { index, value in
                "Field \(index + 1): \(CardText.plainText(String(value)))"
            }.joined(separator: "\n")
        } else {
            fields = "Note unavailable"
        }

        let history: String
        if let stats {
            let recent = stats.revlog.prefix(5).map {
                "rating=\($0.rating), interval=\($0.intervalSecs)s"
            }.joined(separator: ", ")
            let stability = stats.stability.map { String($0) } ?? "unknown"
            let difficulty = stats.difficulty.map { String($0) } ?? "unknown"
            let retrievability = stats.retrievabilityPct.map { String($0) } ?? "unknown"
            history = """
            Stability: \(stability)
            Difficulty: \(difficulty)
            Retrievability: \(retrievability)
            Recent reviews: \(recent.isEmpty ? "none" : recent)
            """
        } else {
            history = "Card statistics unavailable"
        }

        return """
        Deck: \(snapshot.deckName)
        Card ID: \(cardID)
        Queue remaining: \(snapshot.remainingNew) new, \(snapshot.remainingLearning) learning, \(snapshot.remainingReview) review
        Fields:
        \(fields)

        \(history)
        """
    }

    private func ensureProfileUnchanged(_ expected: ProfileContext) throws {
        guard AccountStore.shared.selectedContext == expected else {
            throw AssistantError.profileChanged
        }
    }

    private func userFacingMessage(for error: any Error) -> String {
        if let error = error as? AssistantError {
            return switch error {
            case .profileChanged:
                "The active profile changed. Ask again in the new profile."
            case .noCurrentCard:
                "Open a card in Review first, then ask again."
            }
        }
        return error.localizedDescription
    }

    private static func totalDue(in tree: [DeckTreeNode]) -> DeckCounts {
        tree.reduce(into: DeckCounts.zero) { total, node in
            total = DeckCounts(
                newCount: total.newCount + node.counts.newCount,
                learnCount: total.learnCount + node.counts.learnCount,
                reviewCount: total.reviewCount + node.counts.reviewCount
            )
        }
    }

    private static func noteReference(_ record: NoteRecord) -> String {
        let values = record.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        let fields = values.enumerated().map { index, value in
            "Field \(index + 1): \(CardText.plainText(String(value)))"
        }.joined(separator: "\n")
        return """
        Note ID: \(record.id.rawValue)
        Title: \(CardText.plainText(record.sfld))
        \(fields)
        Tags: \(record.tags)
        """
    }

    private static func deterministicCollectionAnswer(_ records: [NoteRecord]) -> String {
        let titles = records.prefix(4).map {
            "• \(String(CardText.plainText($0.sfld).prefix(160)))"
        }
        return "I found \(records.count) matching note\(records.count == 1 ? "" : "s"):\n\(titles.joined(separator: "\n"))\n\nEnable Apple Intelligence in Settings for a grounded synthesis of these notes."
    }
}

private struct AssistantResult: Sendable {
    let text: String
    let citations: [AssistantCitation]
}

enum AssistantError: LocalizedError {
    case profileChanged
    case noCurrentCard

    var errorDescription: String? {
        switch self {
        case .profileChanged: "The active profile changed."
        case .noCurrentCard: "No card is currently open."
        }
    }
}
