import AmgiAppShared
import AmgiAppCore
import AmgiUI
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import Testing
@testable import DecksFeature

@MainActor @Suite struct DeckDecisionModelTests {
    private actor Choices {
        var metadata = DeckDecisionMetadata()
        var paused = false
        var failPause = false
        func failNextPause() { failPause = true }
        func isPaused() -> Bool { paused }
        func read() -> DeckDecisionMetadata { metadata }
        func mutate(_ mutation: DeckDecisionMutation) throws -> DeckDecisionResult {
            let old = metadata
            switch mutation {
            case .observe(let observations, let ids, let now):
                metadata.observe(observations, existingIDs: ids, now: now)
            case .suppress(let id, let issue, let until):
                var entry = metadata.entries[String(id.rawValue)] ?? .init()
                entry.suppressedUntil[issue] = until
                metadata.entries[String(id.rawValue)] = entry
            case .pause where failPause:
                paused = true
                metadata.entries["7"] = .init(pause: .init(cardIDs: [1], status: .pending))
                throw DeckDecisionFailure(message: "Couldn't confirm Pause", collectionChanged: true)
            default: break
            }
            return DeckDecisionResult(metadata: metadata, metadataChanged: old != metadata)
        }
    }
    private func model(choices: Choices) -> DeckListModel {
        var deck = DeckClient()
        deck.fetchTree = {
            let paused = await choices.isPaused()
            return [DeckTreeNode(id: DeckID(7), name: "Deck", fullName: "Deck",
                counts: paused ? .zero : DeckCounts(newCount: 20, learnCount: 0, reviewCount: 0),
                cardCount: 100, uncappedCounts: paused ? .zero : DeckCounts(newCount: 20, learnCount: 0, reviewCount: 30))]
        }
        var cards = CardClient()
        cards.searchIds = { _, _ in await choices.isPaused() ? [CardID(1)] : [] }
        var client = DeckDecisionClient.testValue
        client.read = { _ in await choices.read() }
        client.mutate = { _, mutation in try await choices.mutate(mutation) }
        return withDependencies {
            $0.deckClient = deck
            $0.cardClient = cards
            $0.deckDecisionClient = client
            $0.statsClient = StatsClient(fetchGraphs: { _, _ in
                var graph = GraphsSnapshot()
                graph.reviews.count[-47] = .init(learn: 0, relearn: 0, young: 1, mature: 0, filtered: 0)
                return graph
            }, graduatedToday: { _ in 0 }, learningDueToday: { _ in 0 }, lastRating: { _ in nil })
        } operation: {
            let store = CollectionStore()
            return withDependencies { $0.collectionStore = store } operation: { DeckListModel() }
        }
    }
    private func decisions(_ model: DeckListModel) -> DeckTriageData {
        guard case .loaded(_, _, _, let triage) = model.state else { return .unresolved }
        return triage
    }
    @Test func returningWithoutStudyingOrSavingDoesNotResolve() async throws {
        let value = model(choices: Choices())
        await value.load()
        #expect(decisions(value).items.count == 1)
        // Review/editor cancellation only refreshes; it does not acknowledge.
        await value.load()
        #expect(decisions(value).items.count == 1)
    }
    @Test func deferralRemovesTheDecisionAndSurvivesANewModel() async throws {
        let choices = Choices()
        let value = model(choices: choices)
        await value.load()
        let item = try #require(decisions(value).focusedItem)
        #expect(await value.decide(item, action: .deferDecision))
        #expect(decisions(value).isHidden)
        let reloaded = model(choices: choices)
        await reloaded.load()
        #expect(decisions(reloaded).isHidden)
    }
    @Test func successfulSettingsSaveAcknowledgesTheDecision() async throws {
        let value = model(choices: Choices())
        await value.load()
        let item = try #require(decisions(value).focusedItem)
        await value.acknowledgeSavedSettings(item)
        #expect(decisions(value).isHidden)
    }
    @Test func settingsAcknowledgmentRejectsAnOldCollectionActivation() async throws {
        let value = model(choices: Choices())
        await value.load()
        let item = try #require(decisions(value).focusedItem)
        let target = DeckListModel.DecisionTarget(deck: DeckTreeNode(id: DeckID(item.id), name: "Deck", fullName: "Deck"),
            profile: AccountStore.shared.selectedContext,
            scope: DeckDecisionScope(mediaPath: "test", activationID: UUID()))
        await value.acknowledgeSavedSettings(item, target: target)
        #expect(decisions(value).items.count == 1)
    }
    @Test func partialPauseKeepsARecoveryDecisionAndItsErrorAfterRefresh() async throws {
        let choices = Choices()
        let value = model(choices: choices)
        await value.load()
        let original = try #require(decisions(value).focusedItem)
        await choices.failNextPause()
        #expect(!(await value.decide(original, action: .pause)))
        let recovery = try #require(decisions(value).focusedItem)
        #expect(recovery.actions == [.chooseCards, .viewDeck])
        #expect(decisions(value).errorMessage == "Couldn't confirm Pause")
        value.decisionError = nil // dismissing the alert keeps the inline error
        await value.load()
        #expect(decisions(value).errorMessage == "Couldn't confirm Pause")
        #expect(await value.decide(recovery, action: .deferDecision))
        #expect(decisions(value).isHidden)
    }
}
