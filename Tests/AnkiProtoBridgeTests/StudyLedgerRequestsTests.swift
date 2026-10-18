import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct StudyLedgerRequestsTests {
    @Test func ledgerRequestUsesAuxiliaryReadEndpoint() throws {
        let request: Request<StudyLedger> = .studyLedger(
            deckId: 42,
            rolloverHour: 4,
            days: [.init(offset: 1, startMs: 1_000, endMs: 2_000)],
            detailOffset: 1
        )
        #expect(request.serviceId == 200)
        #expect(request.methodId == 8)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["deck_id"] as? Int64 == 42)
        #expect(body["rollover_hour"] as? Int == 4)
        #expect(body["detail_offset"] as? Int == 1)
        let days = try #require(body["days"] as? [[String: Any]])
        #expect(days.first?["start_ms"] as? Int64 == 1_000)
        #expect(days.first?["end_ms"] as? Int64 == 2_000)
    }

    /// Today rebuilt from the log equals the engine's own deck list, through
    /// the packaged framework and the Swift decoder.
    @Test func packagedBridgeRebuildsTodayAsTheDeckListShowsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("study-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = try AnkiBackend(preferredLangs: ["en"])
        try backend.openCollection(
            collectionPath: dir.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: dir.appendingPathComponent("media").path,
            mediaDbPath: dir.appendingPathComponent("media.db").path
        )
        defer { try? backend.closeCollection() }
        let basic = try #require(backend.invoke(.notetypeNames).first { $0.name == "Basic" })
        for i in 0..<30 {
            try backend.invoke(.addNote(template: NewNoteTemplate(notetypeId: basic.id, fields: ["Front \(i)", "Back"]), deckId: DeckID(1)))
        }
        for _ in 0..<2 {
            let queued = try #require(backend.invoke(.getQueuedCards(fetchLimit: 1)).cards.first)
            try backend.invoke(.answerReviewCard(cardId: queued.card.id, rating: .easy, timeSpentMs: 1_000, states: queued.states))
        }

        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = .current
        var start = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: now)!
        if start > now { start = calendar.date(byAdding: .day, value: -1, to: start)! }
        let window = StudyLedger.Window(
            offset: 0,
            startMs: Int64(start.timeIntervalSince1970 * 1_000),
            // The deck list looks 20 minutes ahead for learning cards.
            endMs: Int64(now.addingTimeInterval(1_200).timeIntervalSince1970 * 1_000)
        )
        let ledger = try backend.invoke(.studyLedger(deckId: 0, rolloverHour: 4, days: [window], detailOffset: 0))
        let day = try #require(ledger.days.first)
        let tree = try backend.invoke(.deckTree(at: now))
        let shown = tree.reduce(StudyLedger.Counts()) {
            StudyLedger.Counts(new: $0.new + $1.counts.newCount, learn: $0.learn + $1.counts.learnCount, review: $0.review + $1.counts.reviewCount)
        }
        #expect(day.left == shown)
        #expect(day.left == StudyLedger.Counts(new: 18, learn: 0, review: 0))
        #expect(day.due == StudyLedger.Counts(new: 20, learn: 0, review: 0))
        #expect(day.studied.new == 2)
        #expect(day.studied.millis == 2_000)
        #expect(day.exact)
        #expect(day.detail?.leftIds.isEmpty == true)
    }
}
