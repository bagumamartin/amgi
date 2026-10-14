import Foundation
import SQLite3

public struct RetrievalSegment: Codable, Hashable, Sendable, Identifiable {
    public enum Modality: String, Codable, Sendable { case text, image, audio, video, mixed }
    public var id: String
    public var sourceID: String
    public var title: String
    public var text: String
    public var modality: Modality
    public var anchor: String
    public var sourceURL: URL?
    public var fingerprint: String
    public var vector: [Float]?
    public var imageHash: UInt64?
    public init(id: String, sourceID: String, title: String, text: String, modality: Modality = .text, anchor: String = "", sourceURL: URL? = nil, fingerprint: String, vector: [Float]? = nil, imageHash: UInt64? = nil) {
        self.id = id; self.sourceID = sourceID; self.title = title; self.text = text; self.modality = modality
        self.anchor = anchor; self.sourceURL = sourceURL; self.fingerprint = fingerprint; self.vector = vector; self.imageHash = imageHash
    }
}
public struct RetrievalHit: Sendable, Identifiable {
    public var id: String { segment.id }
    public let segment: RetrievalSegment
    public let score: Float
}

/// Metadata, source anchors, lexical FTS and vectors commit together. Each
/// segment is resumable; sources are pruned only after a complete source scan.
public actor RetrievalIndex {
    private let database: RetrievalDatabase
    public init(url: URL, identity: String = TextEmbedder.modelIdentity) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try RetrievalDatabase(url: url)
        try database.execute("CREATE TABLE IF NOT EXISTS metadata(identity TEXT NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS segments(id TEXT PRIMARY KEY, source TEXT NOT NULL, payload BLOB NOT NULL)")
        try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS lexical USING fts5(id UNINDEXED, title, text, tokenize='unicode61 remove_diacritics 2')")
        let existing = try database.strings("SELECT identity FROM metadata", column: 0).first
        if existing != identity {
            try database.transaction {
                try database.execute("DELETE FROM segments"); try database.execute("DELETE FROM lexical"); try database.execute("DELETE FROM metadata")
                try database.execute("INSERT INTO metadata VALUES (?)", bindings: [identity])
            }
        }
    }
    public func cached(_ id: String, fingerprint: String) throws -> RetrievalSegment? {
        let row = try database.payloads("SELECT payload FROM segments WHERE id = ?", bindings: [id]).first
        guard let row, let segment = try? JSONDecoder().decode(RetrievalSegment.self, from: row), segment.fingerprint == fingerprint else { return nil }
        return segment
    }
    public func upsert(_ segment: RetrievalSegment) throws {
        if let vector = segment.vector {
            guard vector.count == TextEmbedder.dimensionValue, vector.allSatisfy(\.isFinite) else { throw RetrievalError.invalidVector }
        }
        let data = try JSONEncoder().encode(segment)
        try database.transaction {
            try database.execute("INSERT OR REPLACE INTO segments VALUES (?, ?, ?)", bindings: [segment.id, segment.sourceID], blob: data)
            try database.execute("DELETE FROM lexical WHERE id = ?", bindings: [segment.id])
            try database.execute("INSERT INTO lexical(id,title,text) VALUES (?, ?, ?)", bindings: [segment.id, segment.title, segment.text])
        }
    }
    public func pruneSource(_ source: String, keeping ids: Set<String>) throws {
        let existing = try database.strings("SELECT id FROM segments WHERE source = ?", bindings: [source], column: 0)
        try database.transaction {
            for id in existing where !ids.contains(id) {
                try database.execute("DELETE FROM segments WHERE id = ?", bindings: [id])
                try database.execute("DELETE FROM lexical WHERE id = ?", bindings: [id])
            }
        }
    }
    public func pruneSources(prefix: String, keeping sources: Set<String>) throws {
        let existing = try database.strings("SELECT DISTINCT source FROM segments", column: 0)
        for source in existing where source.hasPrefix(prefix) && !sources.contains(source) { try pruneSource(source, keeping: []) }
    }
    public func count() throws -> Int { try database.strings("SELECT count(*) FROM segments", column: 0).first.flatMap(Int.init) ?? 0 }
    public func search(_ query: String, vector: [Float]? = nil, limit: Int = 12) throws -> [RetrievalHit] {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(20)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
        let lexicalIDs = try database.strings("SELECT id FROM lexical WHERE lexical MATCH ? ORDER BY bm25(lexical,0,2,1) LIMIT 100", bindings: [match], column: 0)
        let ranks = Dictionary(uniqueKeysWithValues: lexicalIDs.enumerated().map { ($0.element, $0.offset) })
        let all = try database.payloads("SELECT payload FROM segments").compactMap { try? JSONDecoder().decode(RetrievalSegment.self, from: $0) }
        var semantic: [String: Float] = [:]
        if let vector {
            // Standardize within modality to avoid one modality dominating solely
            // from its native cosine distribution. Calibrate fusion via fixtures.
            for modality in [RetrievalSegment.Modality.text, .image, .audio, .video, .mixed] {
                let group = all.filter { $0.modality == modality && $0.vector != nil }
                let scores = group.map { ($0.id, TextEmbedder.cosine(vector, $0.vector!)) }.filter { $0.1.isFinite }
                let n = Float(scores.count)
                guard n > 0 else { continue }
                let mean = scores.reduce(Float(0)) { $0 + $1.1 } / n
                let deviation = max(0.01, (scores.reduce(Float(0)) { $0 + pow($1.1 - mean, 2) } / n).squareRoot())
                for (id, score) in scores { semantic[id] = (score - mean) / deviation }
            }
        }
        // Reciprocal-rank fusion is scale independent. Exact lookup gets a
        // separate stable boost; do not copy another app's BM25/cosine weights.
        let semanticRanks = Dictionary(uniqueKeysWithValues: semantic.sorted { $0.value > $1.value }.enumerated().map { ($0.element.key, $0.offset) })
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var best: [String: RetrievalHit] = [:]
        for segment in all {
            let lexical = ranks[segment.id].map { 1 / Float(20 + $0) } ?? 0
            let sem = semanticRanks[segment.id].map { 1 / Float(20 + $0) } ?? 0
            guard lexical > 0 || sem > 0 else { continue }
            let exact = segment.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedQuery) ? Float(0.05) : 0
            let score = lexical + sem + exact
            if best[segment.sourceID].map({ $0.score < score }) ?? true { best[segment.sourceID] = RetrievalHit(segment: segment, score: score) }
        }
        return Array(best.values.sorted { $0.score > $1.score }.prefix(max(0, limit)))
    }
}

enum RetrievalError: Error { case database(String), invalidVector }

/// The owning actor is the sole caller. SQLite's FULLMUTEX mode additionally
/// guards its C handle; no handle or statement escapes this wrapper.
private final class RetrievalDatabase: @unchecked Sendable {
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else { throw RetrievalError.database("Open failed") }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
    }
    deinit { sqlite3_close(db) }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func statement(_ sql: String, bindings: [String], blob: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
        for (index, value) in bindings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        if let blob { _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(bindings.count + 1), $0.baseAddress, Int32($0.count), transient) } }
        return statement
    }
    func execute(_ sql: String, bindings: [String] = [], blob: Data? = nil) throws {
        let statement = try statement(sql, bindings: bindings, blob: blob); defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
    }
    func strings(_ sql: String, bindings: [String] = [], column: Int32) throws -> [String] {
        let statement = try statement(sql, bindings: bindings); defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let string = sqlite3_column_text(statement, column) { result.append(String(cString: string)) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
        return result
    }
    func payloads(_ sql: String, bindings: [String] = []) throws -> [Data] {
        let statement = try statement(sql, bindings: bindings); defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) { result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
        return result
    }
}
