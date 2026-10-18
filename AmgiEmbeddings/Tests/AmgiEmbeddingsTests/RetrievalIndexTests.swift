import Foundation
import SQLite3
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

    private static func unit(_ hot: Int, _ warm: Int? = nil) -> [Float] {
        var vector = [Float](repeating: 0, count: TextEmbedder.dimensionValue)
        vector[hot] = 1
        if let warm { vector[warm] = 0.6; vector[hot] = 0.8 }
        return vector
    }
    private static func fresh() throws -> (RetrievalIndex, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try RetrievalIndex(url: directory.appendingPathComponent("index.sqlite")), directory)
    }

    @Test func quantizedVectorsRankByCosineAndFilterBySource() async throws {
        let (index, directory) = try Self.fresh()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.upsert(.init(id: "note:1:passage:0", sourceID: "note:1", title: "A", text: "alpha", fingerprint: "x", vector: Self.unit(0)))
        try await index.upsert(.init(id: "note:2:passage:0", sourceID: "note:2", title: "B", text: "beta", fingerprint: "x", vector: Self.unit(0, 1)))
        try await index.upsert(.init(id: "book:9:chapter:1:passage:0", sourceID: "book:9", title: "Book", text: "gamma", fingerprint: "x", vector: Self.unit(0)))
        let all = try await index.search("", vector: Self.unit(0), limit: 3)
        #expect(Set(all.prefix(2).map(\.segment.sourceID)) == ["note:1", "book:9"])
        #expect(all.allSatisfy { $0.segment.vector == nil })
        let notes = try await index.search("", vector: Self.unit(0), limit: 3, filter: .init(sourcePrefixes: ["note:"]))
        #expect(notes.map(\.segment.sourceID) == ["note:1", "note:2"])
        let neighbours = try await index.neighbors(of: "note:1", limit: 2, filter: .init(sourcePrefixes: ["note:"]))
        #expect(neighbours.map(\.segment.sourceID) == ["note:2"])
        // Removing a segment drops it from the in-memory table too.
        try await index.pruneSource("note:2", keeping: [])
        #expect(try await index.search("", vector: Self.unit(0), limit: 3, filter: .init(sourcePrefixes: ["note:"])).count == 1)
    }

    @Test func coverageListsTheLeastSimilarPassagesFirst() async throws {
        let (index, directory) = try Self.fresh()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.upsert(.init(id: "note:1:passage:0", sourceID: "note:1", title: "Card", text: "covered", fingerprint: "x", vector: Self.unit(0)))
        try await index.upsert(.init(id: "book:9:chapter:1:passage:0", sourceID: "book:9", title: "Book", text: "covered", fingerprint: "x", vector: Self.unit(0)))
        try await index.upsert(.init(id: "book:9:chapter:1:passage:1", sourceID: "book:9", title: "Book", text: "new idea", fingerprint: "x", vector: Self.unit(5)))
        try await index.upsert(.init(id: "book:9:chapter:2:passage:0", sourceID: "book:9", title: "Book", text: "other chapter", fingerprint: "x", vector: Self.unit(7)))
        let gaps = try await index.coverage(of: .init(idPrefixes: ["book:9:chapter:1:passage:"]), against: .init(sourcePrefixes: ["note:"]))
        #expect(gaps.map(\.segment.text) == ["new idea", "covered"])
        #expect(abs(gaps[1].nearest - 1) < 0.02)
    }

    @Test func sourceFingerprintsArePrunedWithTheirSources() async throws {
        let (index, directory) = try Self.fresh()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.upsert(.init(id: "note:1:passage:0", sourceID: "note:1", title: "A", text: "alpha", fingerprint: "x"))
        try await index.recordSources(["note:1": "100|t1", "note:2": "200|t1"])
        #expect(try await index.sourceFingerprints(prefix: "note:") == ["note:1": "100|t1", "note:2": "200|t1"])
        try await index.pruneSources(prefix: "note:", keeping: ["note:2"])
        #expect(try await index.sourceFingerprints(prefix: "note:") == ["note:2": "200|t1"])
        #expect(try await index.count() == 0)
    }

    @Test func japaneseTextIsLexicallySearchable() async throws {
        let (index, directory) = try Self.fresh()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.upsert(.init(id: "a", sourceID: "note:1", title: "単語", text: "東京大学は日本の大学です。", fingerprint: "x"))
        try await index.upsert(.init(id: "b", sourceID: "note:2", title: "単語", text: "京都に行きました。", fingerprint: "x"))
        #expect(try await index.search("大学").map(\.segment.id) == ["a"])
        #expect(try await index.search("京都").map(\.segment.id) == ["b"])
    }

    @Test func legacyIndexesKeepTheirVectorsAcrossTheSchemaMove() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("index.sqlite")
        let legacy = RetrievalSegment(id: "note:1:passage:0", sourceID: "note:1", title: "A", text: "warfarin", fingerprint: "f", vector: Self.unit(3))
        let payload = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        let script = """
        CREATE TABLE metadata(identity TEXT NOT NULL); INSERT INTO metadata VALUES ('fixture');
        CREATE TABLE segments(id TEXT PRIMARY KEY, source TEXT NOT NULL, payload BLOB NOT NULL);
        INSERT INTO segments VALUES ('note:1:passage:0', 'note:1', CAST('\(payload)' AS BLOB));
        CREATE VIRTUAL TABLE lexical USING fts5(id UNINDEXED, title, text, tokenize='unicode61 remove_diacritics 2');
        """
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, script, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let index = try RetrievalIndex(url: url, identity: "fixture")
        #expect(try await index.cached("note:1:passage:0", fingerprint: "f") != nil)
        #expect(try await index.search("", vector: Self.unit(3)).first?.segment.id == "note:1:passage:0")
        #expect(try await index.search("warfarin").count == 1)
    }
}
