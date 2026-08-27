import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
public import Dependencies
import DependenciesMacros
import Logging

private let logger = Logger(label: "com.ankiapp.card.client")

extension CardClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        @Dependency(\.schedulerService) var scheduler
        @Dependency(\.decksService) var decks

        return Self(
            fetchDue: { deckId in
                try await backendOffload {
                    do {
                        try decks.setCurrentDeck(deckId)
                        logger.info("Set current deck to \(deckId)")
                    } catch {
                        logger.error("setCurrentDeck failed for deckId=\(deckId): \(error)")
                        throw error
                    }

                    do {
                        let currentDeck = try decks.getCurrentDeck()
                        logger.info("Verified current deck: id=\(currentDeck.id), name=\(currentDeck.name)")
                    } catch {
                        logger.warning("Could not verify current deck (non-fatal): \(error)")
                    }

                    do {
                        let result = try scheduler.getQueuedCards(200)
                        logger.info("QueuedCards for deckId=\(deckId): \(result.cards.count) cards")
                        return result.cards.map(\.card)
                    } catch {
                        logger.error("fetchDue failed for deckId=\(deckId): \(error)")
                        throw error
                    }
                }
            },
            fetchByNote: { noteId in
                // Engine exposes no batch getCards; a note owns 1–3 cards
                // so per-card fetch after an id search is the honest path.
                let ids = try await backend.invoke(.searchCardIds(query: "nid:\(noteId.rawValue)"))
                return try await backendOffload {
                    try ids.map { try backend.invoke(.getCard(id: $0)) }
                }
            },
            getCard: { cardId in
                try await backend.invoke(.getCard(id: cardId))
            },
            save: { card in
                try await backend.invoke(.updateCards(cards: [card]))
            },
            answer: { cardId, rating, timeSpent in
                try await backendOffload { try scheduler.answerCard(cardId, rating, timeSpent) }
            },
            undo: { _ in },
            suspend: { cardId in
                try await backend.invoke(.suspendCards(cardIds: [cardId]))
            },
            bury: { cardId in
                try await backend.invoke(.buryUserCards(cardIds: [cardId], noteIds: []))
            },
            flag: { cardId, value in
                try await backend.invoke(.setFlag(cardIds: [cardId], flag: value))
            },
            resetToNew: { cardId in
                try await backend.invoke(.scheduleCardsAsNew(cardIds: [cardId], log: true))
            },
            undoLast: {
                try await backend.invoke(.undoLastAction)
            },
            redoLast: {
                try await backend.invoke(.redoLastAction)
            },
            undoStatus: {
                try await backend.invoke(.undoStatus)
            },
            getCardFlags: { cardId in
                let card = try await backend.invoke(.getCard(id: cardId))
                return UInt32(card.flags) & 0b111
            },
            hasUndoableAction: {
                try await backend.invoke(.hasUndoableAction)
            },
            removeCards: { cardIds in
                try await backend.invoke(.removeCards(cardIds: cardIds))
                logger.info("Removed \(cardIds.count) cards")
            },
            searchIds: { query, order in
                try await backend.invoke(.searchCardIds(query: query, order: order))
            },
            suspendCards: { cardIds, noteIds in
                try await backend.invoke(.suspendCards(cardIds: cardIds, noteIds: noteIds))
                logger.info("Suspended \(cardIds.count) cards / \(noteIds.count) notes")
            },
            restoreBuriedAndSuspended: { cardIds in
                try await backend.invoke(.restoreBuriedAndSuspendedCards(cardIds: cardIds))
                logger.info("Restored \(cardIds.count) buried/suspended cards")
            },
            buryUserCards: { cardIds, noteIds in
                try await backend.invoke(.buryUserCards(cardIds: cardIds, noteIds: noteIds))
                logger.info("Buried \(cardIds.count) cards / \(noteIds.count) notes")
            },
            setDueDate: { cardIds, daysExpression in
                try await backend.invoke(.setDueDate(cardIds: cardIds, daysExpression: daysExpression))
                logger.info("Set due date '\(daysExpression)' on \(cardIds.count) cards")
            },
            gradeNow: { cardIds, rating in
                try await backend.invoke(.gradeNow(cardIds: cardIds, rating: rating))
                logger.info("Grade now \(rating) on \(cardIds.count) cards")
            },
            repositionCards: { cardIds, startingFrom, stepSize, randomize, shiftExisting in
                let count = try await backend.invoke(
                    .sortCards(
                        cardIds: cardIds,
                        startingFrom: startingFrom,
                        stepSize: stepSize,
                        randomize: randomize,
                        shiftExisting: shiftExisting
                    )
                )
                logger.info("Repositioned \(count) cards")
                return count
            },
            changeDeck: { cardIds, deckId in
                let count = try await backend.invoke(.setDeck(cardIds: cardIds, deckId: deckId))
                logger.info("Moved \(count) cards to deck \(deckId)")
                return count
            }
        )
    }()
}
