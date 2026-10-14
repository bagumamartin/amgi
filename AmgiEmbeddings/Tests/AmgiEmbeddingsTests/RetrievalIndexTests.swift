import Foundation
import Testing
@testable import AmgiEmbeddings

@Suite("Retrieval transactions")
struct RetrievalIndexTests {
    @Test func lexicalAnchorsSurviveReopenAndIdentityMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let index = try RetrievalIndex(url: url, identity: "fixture-one")
        try await index.upsert(.init(id: "page:2", sourceID: "pdf:one", title: "Pharmacology", text: "Warfarin inhibits vitamin K recycling.", anchor: "page:2", fingerprint: "a"))
        let hits = try await index.search("vitamin K")
        #expect(hits.first?.segment.anchor == "page:2")
        let reopened = try RetrievalIndex(url: url, identity: "fixture-one")
        #expect(try await reopened.count() == 1)
        let migrated = try RetrievalIndex(url: url, identity: "fixture-two")
        #expect(try await migrated.count() == 0)
    }
    @Test func incompleteSourceScanDoesNotPruneOtherSegments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try RetrievalIndex(url: directory.appendingPathComponent("index.sqlite"))
        for page in 0..<4 { try await index.upsert(.init(id: "page:\(page)", sourceID: "pdf", title: "Book", text: "topic \(page)", anchor: "page:\(page)", fingerprint: "one")) }
        try await index.upsert(.init(id: "page:0", sourceID: "pdf", title: "Book", text: "replacement", anchor: "page:0", fingerprint: "two"))
        #expect(try await index.count() == 4)
        try await index.pruneSource("pdf", keeping: ["page:0", "page:1"])
        #expect(try await index.count() == 2)
    }
    @Test func querySyntaxIsPlainTextAndSourcesAreGrouped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try RetrievalIndex(url: directory.appendingPathComponent("index.sqlite"))
        for page in 0..<3 { try await index.upsert(.init(id: "page:\(page)", sourceID: "pdf", title: "Book", text: "calcium channel blocker", anchor: "page:\(page)", fingerprint: "one")) }
        #expect(try await index.search("\"calcium\" OR (blocker*)").count == 1)
    }
    @Test func passagesCoverTailAndOverlap() {
        let text = String(repeating: "a", count: 2000) + "TAIL"
        let passages = MediaIndexer.passages(text, width: 500, overlap: 100)
        #expect(passages.last?.hasSuffix("TAIL") == true)
        #expect(passages.count == 5)
    }
}
