import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct StudyHistoryRequestsTests {
    @Test func historyRequestUsesAuxiliaryReadEndpoint() throws {
        let request: Request<StudyHistory> = .studyHistory(scope: "deck:French", dayEndMs: 123_456_000, rolloverHour: 4)
        #expect(request.serviceId == 200)
        #expect(request.methodId == 5)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["scope_search"] as? String == "deck:French")
        #expect(body["day_end_ms"] as? Int64 == 123_456_000)
        #expect(body["rollover_hour"] as? Int == 4)
    }

    @Test func packagedBridgeReturnsBrowsableIdsAndFollowsCollectionSwitches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("study-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = try AnkiBackend(preferredLangs: ["en"])
        func open(_ name: String) throws {
            let root = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try backend.openCollection(collectionPath: root.appendingPathComponent("collection.anki2").path,
                mediaFolderPath: root.appendingPathComponent("media").path,
                mediaDbPath: root.appendingPathComponent("media.db").path)
        }
        try open("first")
        defer { try? backend.closeCollection() }
        let basic = try #require(backend.invoke(.notetypeNames).first { $0.name == "Basic" })
        try backend.invoke(.addNote(template: NewNoteTemplate(notetypeId: basic.id, fields: ["Front", "Back"]), deckId: DeckID(1)))
        let end = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1_000)
        let initial = try backend.invoke(.studyHistory(scope: "", dayEndMs: end, rolloverHour: 4))
        #expect(initial.newCandidateIds.count == 1)
        let browsed = try backend.invoke(.searchCardIds(query: StudyHistory.search(ids: initial.inspectableIds)))
        #expect(browsed.map(\.rawValue) == initial.inspectableIds)
        let largeSelection = Array(Int64(1)...10_001) + initial.inspectableIds
        #expect(try backend.invoke(.searchCardIds(query: StudyHistory.search(ids: largeSelection))) == browsed)
        let queued = try #require(backend.invoke(.getQueuedCards(fetchLimit: 1)).cards.first)
        try backend.invoke(.answerReviewCard(cardId: queued.card.id, rating: .good, timeSpentMs: 1000, states: queued.states))
        let learned = try backend.invoke(.studyHistory(scope: "", dayEndMs: end, rolloverHour: 4))
        #expect(learned.learningIds == [queued.card.id.rawValue])
        #expect(learned.newCandidateIds.isEmpty)
        try backend.closeCollection()
        try open("second")
        #expect(try backend.invoke(.studyHistory(scope: "", dayEndMs: end, rolloverHour: 4)).inspectableIds.isEmpty)
        try backend.closeCollection()
        try open("first")
        #expect(try backend.invoke(.studyHistory(scope: "", dayEndMs: end, rolloverHour: 4)) == learned)
    }
}
