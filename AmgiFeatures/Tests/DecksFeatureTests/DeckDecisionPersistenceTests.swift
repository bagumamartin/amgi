import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import Foundation
import Testing
@testable import DecksFeature

/// Real isolated collections validate lifecycle fencing and durable config
/// reads. They do not use the user's collection or make network sync claims.
@Suite struct DeckDecisionPersistenceTests {
    @Test func remindersSurviveReopenAndOldActivationsCannotWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ijuka-decision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backend = try AnkiBackend(preferredLangs: ["en"])
        defer {
            try? backend.closeCollection()
            try? FileManager.default.removeItem(at: folder)
        }
        func open(_ name: String) throws {
            let path = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try backend.openCollection(collectionPath: path.appendingPathComponent("collection.anki2").path,
                mediaFolderPath: path.appendingPathComponent("collection.media").path,
                mediaDbPath: path.appendingPathComponent("collection.media.db").path)
        }
        try open("first")
        let client = DeckDecisionClient.live(backend: backend)
        let first = try #require(client.scope())
        let now = Date()
        _ = try await client.mutate(first, .observe([7: "empty"], existingIDs: [7], now: now))
        let template: DeckTemplate = try await backend.invoke(.newDeck)
        let deck: DeckCreation = try await backend.invoke(.addDeck(template: template, name: "Reminders"))
        let until = now.addingTimeInterval(7 * 86_400)
        _ = try await client.mutate(first, .suppress(deck.id, issue: "inactive", until: until))
        let syncedValue = try await client.read(first)
        try backend.closeCollection()
        try open("second")
        let second = try #require(client.scope())
        #expect(try await client.read(second).entries.isEmpty)
        // The synced config representation preserves its dates and namespace
        // when applied to another collection; this is not a network sync run.
        try backend.setConfigJSONValue(syncedValue, for: DeckDecisionClient.configKey)
        #expect(try await client.read(second).isSuppressed(id: deck.id.rawValue, issue: "inactive", now: now))
        do {
            _ = try await client.mutate(first, .observe([7: "unused"], existingIDs: [7], now: now))
            Issue.record("An old profile activation must not write")
        } catch is DeckDecisionFailure {}
        try backend.closeCollection()
        try open("first")
        let reopened = try #require(client.scope())
        #expect(reopened.activationID != first.activationID)
        #expect(throws: BackendError.self) {
            try AnkiBackend.$requiredCollectionActivationID.withValue(first.activationID) {
                let _: DeckDecisionMetadata? = try backend.getConfigJSONValue(for: DeckDecisionClient.configKey)
            }
        }
        #expect(try await client.read(reopened).entries["7"]?.observedSince == now)
        #expect(try await client.read(reopened).entries[String(deck.id.rawValue)]?.suppressedUntil["inactive"] == until)
        do {
            _ = try await client.read(first)
            Issue.record("Reopening the same path must also revoke old scopes")
        } catch is DeckDecisionFailure {}
    }

    @Test func realPauseIncludesChildrenAndPreservesPreviouslySuspendedCards() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ijuka-real-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backend = try AnkiBackend(preferredLangs: ["en"])
        defer {
            try? backend.closeCollection()
            try? FileManager.default.removeItem(at: folder)
        }
        try backend.openCollection(collectionPath: folder.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: folder.appendingPathComponent("media").path, mediaDbPath: folder.appendingPathComponent("media.db").path)
        func deck(_ name: String) throws -> DeckID {
            let template: DeckTemplate = try backend.invoke(.newDeck)
            let result: DeckCreation = try backend.invoke(.addDeck(template: template, name: name))
            return result.id
        }
        let parent = try deck("A*")
        let child = try deck("A*::Child")
        let sibling = try deck("Another")
        let names = try await backend.invoke(.notetypeNames)
        let basic = try #require(names.first { $0.name == "Basic" })
        func addCard(_ id: DeckID, _ front: String) throws {
            var note = try backend.invoke(.newNote(notetypeId: basic.id))
            note.fields[0] = front
            note.fields[1] = "back"
            try backend.invoke(.addNote(template: note, deckId: id))
        }
        try addCard(parent, "parent")
        try addCard(parent, "previously suspended")
        try addCard(child, "child")
        try addCard(sibling, "other")
        let parentIDs = try await backend.invoke(.searchCardIds(query: "did:\(parent.rawValue)", order: nil))
        let oldSuspension = try #require(parentIDs.first)
        try await backend.invoke(.suspendCards(cardIds: [oldSuspension]))
        let childIDs = try await backend.invoke(.searchCardIds(query: "did:\(child.rawValue)", order: nil))
        let expected = Set(parentIDs + childIDs).subtracting([oldSuspension])
        let client = DeckDecisionClient.live(backend: backend)
        let scope = try #require(client.scope())
        let inventory = try await client.target(scope, parent)
        #expect(inventory.cardCount == 3)
        #expect(inventory.uncappedCounts?.newCount == 2)
        let paused = try await client.mutate(scope, .pause(parent))
        #expect(Set(paused.metadata.entries[String(parent.rawValue)]?.pause?.cardIDs ?? []) == Set(expected.map(\.rawValue)))
        #expect(try await backend.invoke(.searchCardIds(query: "did:\(sibling.rawValue) -is:suspended", order: nil)).count == 1)
        _ = try await client.mutate(scope, .resume(parent))
        #expect(try await backend.invoke(.getCard(id: oldSuspension)).queue == -1)
        for id in expected { #expect(try await backend.invoke(.getCard(id: id)).queue == 0) }
    }
}
