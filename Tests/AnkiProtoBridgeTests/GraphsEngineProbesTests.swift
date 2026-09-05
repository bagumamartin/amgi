import Testing
import Foundation
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

/// Behavioral probes for the stats graphs path (user report 2026-09: Stats
/// tab renders all-zero charts on a collection that has cards + review
/// history, with no error). Fires the exact RPC the dashboard uses —
/// `.graphs(search: "", days:)` — against a live scratch engine: first on
/// unreviewed cards (card counts must be non-zero; the reported symptom
/// would fail HERE), then after answering cards through the real queue
/// (today + reviews must be non-zero).
///
/// Runs on macOS (xcframework macOS slice), alongside BrowseEngineProbesTests.
@Suite("Graphs engine probes", .serialized)
struct GraphsEngineProbesTests {
    private struct Scratch {
        let root: URL
        let backend: AnkiBackend
        let cardIDs: [CardID]
    }

    private func openScratch() throws -> Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-graphs-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)

        let mediaFolder = root.appendingPathComponent("media").path
        try FileManager.default.createDirectory(atPath: mediaFolder, withIntermediateDirectories: true)

        let backend = try AnkiBackend(preferredLangs: ["en"])
        try backend.openCollection(
            collectionPath: root.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: mediaFolder,
            mediaDbPath: root.appendingPathComponent("media.db").path
        )

        let names = try backend.invoke(.notetypeNames)
        guard !names.isEmpty else { throw ProbeError("collection must ship default notetypes") }
        let basicID = (names.first { $0.name == "Basic" } ?? names[0]).id

        for pair in [("GraphFront1", "BackOne"), ("GraphFront2", "BackTwo"), ("GraphFront3", "BackThree")] {
            try backend.invoke(.addNote(
                template: NewNoteTemplate(notetypeId: basicID, fields: [pair.0, pair.1]),
                deckId: DeckID(1)
            ))
        }

        let cardIDs = try backend.invoke(.searchCardIds(query: "deck:\"Default\""))
        guard cardIDs.count == 3 else { throw ProbeError("expected 3 cards, got \(cardIDs.count)") }
        return Scratch(root: root, backend: backend, cardIDs: cardIDs)
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    private func cleanup(_ scratch: Scratch) {
        _ = scratch.backend
        try? FileManager.default.removeItem(at: scratch.root)
    }

    @Test func graphsReflectCardsWithoutReviews() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }

        let graphs: GraphsSnapshot = try scratch.backend.invoke(.graphs(search: "", days: 31))
        #expect(graphs.cardCounts.includingInactive.newCards == 3,
                "3 unreviewed cards must show as new — all-zero here reproduces the device report")
        #expect(!graphs.added.added.isEmpty, "added series must cover the note-creation days")
    }

    @Test func graphsReflectAnsweredCards() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let backend = scratch.backend

        let queue = try backend.invoke(.getQueuedCards(fetchLimit: 10))
        guard !queue.cards.isEmpty else { throw ProbeError("expected queued cards") }
        for queued in queue.cards {
            try backend.invoke(.answerReviewCard(
                cardId: queued.card.id,
                rating: .good,
                timeSpentMs: 1000,
                states: queued.states
            ))
        }

        let graphs: GraphsSnapshot = try backend.invoke(.graphs(search: "", days: 31))
        #expect(graphs.today.answerCount == queue.cards.count,
                "today.answerCount must equal answered cards — zero here reproduces the device report")
        #expect(!graphs.reviews.count.isEmpty, "reviews series must cover today after answering")
        #expect(graphs.cardCounts.includingInactive.newCards + graphs.cardCounts.includingInactive.learn
            + graphs.cardCounts.includingInactive.young + graphs.cardCounts.includingInactive.mature > 0,
                "card counts must account for all cards after answering")
    }
}
