import Accelerate
import Foundation
import SQLite3

public struct RetrievalSegment: Codable, Hashable, Sendable, Identifiable {
    public enum Modality: String, Codable, Sendable, CaseIterable { case text, image, audio, video, mixed }
    public var id: String
    public var sourceID: String
    public var title: String
    public var text: String
    public var modality: Modality
    public var anchor: String
    public var sourceURL: URL?
    public var fingerprint: String
    /// Set on segments being written. Segments read back from the index
    /// leave it nil: vectors live in the index's quantized table, not in
    /// each payload.
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
    /// How far the segment's meaning similarity sits above its modality's
    /// mean, in standard deviations. Nil when it wasn't a semantic
    /// candidate. `score` is rank fusion and always has a "best" hit even
    /// when nothing is close; this is the absolute signal for that.
    public let semanticStrength: Float?

    public init(segment: RetrievalSegment, score: Float, semanticStrength: Float? = nil) {
        self.segment = segment
        self.score = score
        self.semanticStrength = semanticStrength
    }
}

/// Which segments a query may return. Empty fields don't restrict.
public struct RetrievalFilter: Sendable, Hashable {
    /// Source IDs must start with one of these ("note:", "book:<id>").
    public var sourcePrefixes: [String]
    /// Segment IDs must start with one of these (one chapter, one page).
    public var idPrefixes: [String]
    /// Only these exact sources (the notes in a deck).
    public var sources: Set<String>?
    public var excludedSources: Set<String>
    public init(sourcePrefixes: [String] = [], idPrefixes: [String] = [], sources: Set<String>? = nil, excludedSources: Set<String> = []) {
        self.sourcePrefixes = sourcePrefixes; self.idPrefixes = idPrefixes; self.sources = sources; self.excludedSources = excludedSources
    }
    public static let all = RetrievalFilter()
    public var isUnrestricted: Bool { sourcePrefixes.isEmpty && idPrefixes.isEmpty && sources == nil && excludedSources.isEmpty }
    func admits(id: String, source: String) -> Bool {
        if !sourcePrefixes.isEmpty, !sourcePrefixes.contains(where: { source.hasPrefix($0) }) { return false }
        if !idPrefixes.isEmpty, !idPrefixes.contains(where: { id.hasPrefix($0) }) { return false }
        if let sources, !sources.contains(source) { return false }
        return !excludedSources.contains(source)
    }
}

/// A passage of one source and how close the nearest admitted segment is.
public struct RetrievalCoverage: Sendable {
    public let segment: RetrievalSegment
    /// Cosine to the closest segment in the comparison set; -1 when that set
    /// is empty.
    public let nearest: Float
}

/// Metadata, source anchors, lexical FTS and vectors commit together. Each
/// segment is resumable; sources are pruned only after a complete source scan.
///
/// Vectors are stored once, as per-row int8 with a scale (768 bytes + 4 per
/// segment instead of ~8 KB of JSON), and kept in one contiguous table in
/// memory after the first query, so a search is a blocked matrix-vector
/// product rather than a decode of every payload. Each indexed source also
/// records a cheap change fingerprint (note mtime, file size and date), so a
/// rescan of an unchanged collection does no per-segment work at all.
public actor RetrievalIndex {
    private static let schema = "2"
    private let database: RetrievalDatabase
    private let identity: String
    private var isPrepared = false
    private var table: VectorTable?

    /// Opens the file only. Schema setup — and the one-time move of a
    /// schema-1 index, which rewrites every row — runs on the actor at first
    /// use, never on the caller's (often the main) thread.
    public init(url: URL, identity: String = TextEmbedder.modelIdentity) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try RetrievalDatabase(url: url)
        self.identity = identity
    }

    private func ready() throws {
        guard !isPrepared else { return }
        try Self.prepare(database, identity: identity)
        isPrepared = true
    }

    private static func prepare(_ database: RetrievalDatabase, identity: String) throws {
        let legacyColumns = try database.strings("SELECT name FROM pragma_table_info('segments')", column: 0)
        let legacyIdentity = try database.strings("SELECT name FROM sqlite_master WHERE type='table' AND name='metadata'", column: 0).isEmpty
            ? nil : try database.strings("SELECT identity FROM metadata", column: 0).first
        try database.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if !legacyColumns.isEmpty, !legacyColumns.contains("vector") {
            try migrateLegacy(database, keep: legacyIdentity == identity)
        }
        try database.execute("CREATE TABLE IF NOT EXISTS segments(id TEXT PRIMARY KEY, source TEXT NOT NULL, fingerprint TEXT NOT NULL, payload BLOB NOT NULL, vector BLOB)")
        try database.execute("CREATE INDEX IF NOT EXISTS segments_source ON segments(source)")
        try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS lexical USING fts5(id UNINDEXED, title, text, tokenize='unicode61 remove_diacritics 2')")
        try database.execute("CREATE TABLE IF NOT EXISTS sources(source TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)")
        try database.execute("DROP TABLE IF EXISTS metadata")
        let stored = try database.strings("SELECT value FROM meta WHERE key = 'identity'", column: 0).first ?? legacyIdentity
        if stored != identity {
            try database.transaction {
                for table in ["segments", "lexical", "sources"] { try database.execute("DELETE FROM \(table)") }
            }
        }
        try database.execute("INSERT OR REPLACE INTO meta VALUES ('identity', ?)", [.text(identity)])
        try database.execute("INSERT OR REPLACE INTO meta VALUES ('schema', ?)", [.text(schema)])
        // Moving the JSON vectors out leaves about two thirds of the file as
        // free pages; so can a model change that clears the index. Reclaim
        // them when they are most of a file worth the rewrite.
        let pages = try database.strings("PRAGMA page_count", column: 0).first.flatMap(Int.init) ?? 0
        let free = try database.strings("PRAGMA freelist_count", column: 0).first.flatMap(Int.init) ?? 0
        if pages > 2_560, free * 2 > pages {
            try database.execute("VACUUM")
            // In WAL mode the rewrite lands in the log; fold it back and
            // truncate, or the log keeps the old file's size.
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Schema 1 kept every vector as JSON inside the payload. Moves them to
    /// the quantized column without re-embedding, and rebuilds the lexical
    /// table so CJK text gets per-character tokens.
    private static func migrateLegacy(_ database: RetrievalDatabase, keep: Bool) throws {
        try database.transaction {
            try database.execute("ALTER TABLE segments RENAME TO segments_v1")
            try database.execute("CREATE TABLE segments(id TEXT PRIMARY KEY, source TEXT NOT NULL, fingerprint TEXT NOT NULL, payload BLOB NOT NULL, vector BLOB)")
            try database.execute("DROP TABLE IF EXISTS lexical")
            try database.execute("CREATE VIRTUAL TABLE lexical USING fts5(id UNINDEXED, title, text, tokenize='unicode61 remove_diacritics 2')")
            if keep {
                for row in try database.blobs("SELECT payload FROM segments_v1") {
                    guard let segment = try? JSONDecoder().decode(RetrievalSegment.self, from: row) else { continue }
                    try write(segment, to: database)
                }
            }
            try database.execute("DROP TABLE segments_v1")
        }
    }

    private static func write(_ segment: RetrievalSegment, to database: RetrievalDatabase) throws {
        var stored = segment
        stored.vector = nil
        let payload = try JSONEncoder().encode(stored)
        let vector: RetrievalDatabase.Value = segment.vector.map { .blob(Quantized($0).data) } ?? .null
        try database.execute("INSERT OR REPLACE INTO segments VALUES (?, ?, ?, ?, ?)", [.text(segment.id), .text(segment.sourceID), .text(segment.fingerprint), .blob(payload), vector])
        try database.execute("DELETE FROM lexical WHERE id = ?", [.text(segment.id)])
        try database.execute("INSERT INTO lexical(id,title,text) VALUES (?, ?, ?)", [.text(segment.id), .text(LexicalForm.indexed(segment.title)), .text(LexicalForm.indexed(segment.text))])
    }

    // MARK: Writing

    /// The stored segment when its fingerprint still matches — and, unless
    /// `requireVector` is false, it was embedded. The returned segment has no
    /// `vector`.
    public func cached(_ id: String, fingerprint: String, requireVector: Bool = true) throws -> RetrievalSegment? {
        try ready()
        let rows = try database.rows("SELECT payload, vector IS NOT NULL FROM segments WHERE id = ? AND fingerprint = ?", [.text(id), .text(fingerprint)])
        guard let row = rows.first, let payload = row.blob(0), !requireVector || row.int(1) == 1 else { return nil }
        return try? JSONDecoder().decode(RetrievalSegment.self, from: payload)
    }
    public func upsert(_ segment: RetrievalSegment) throws {
        try ready()
        if let vector = segment.vector {
            guard vector.count == TextEmbedder.dimensionValue, vector.allSatisfy(\.isFinite) else { throw RetrievalError.invalidVector }
        }
        try database.transaction { try Self.write(segment, to: database) }
        if table != nil {
            if let vector = segment.vector { table?.set(id: segment.id, source: segment.sourceID, modality: segment.modality, vector: Quantized(vector)) }
            else { table?.remove(id: segment.id) }
        }
    }
    public func pruneSource(_ source: String, keeping ids: Set<String>) throws {
        try ready()
        let existing = try database.strings("SELECT id FROM segments WHERE source = ?", [.text(source)], column: 0)
        let removed = existing.filter { !ids.contains($0) }
        guard !removed.isEmpty || ids.isEmpty else { return }
        try database.transaction {
            for id in removed {
                try database.execute("DELETE FROM segments WHERE id = ?", [.text(id)])
                try database.execute("DELETE FROM lexical WHERE id = ?", [.text(id)])
            }
            if ids.isEmpty { try database.execute("DELETE FROM sources WHERE source = ?", [.text(source)]) }
        }
        for id in removed { table?.remove(id: id) }
    }
    public func pruneSources(prefix: String, keeping sources: Set<String>) throws {
        try ready()
        let pattern = RetrievalDatabase.likePrefix(prefix)
        let indexed = try database.strings("SELECT DISTINCT source FROM segments WHERE source LIKE ? ESCAPE '\\'", [.text(pattern)], column: 0)
        for source in indexed where !sources.contains(source) { try pruneSource(source, keeping: []) }
        let recorded = try database.strings("SELECT source FROM sources WHERE source LIKE ? ESCAPE '\\'", [.text(pattern)], column: 0)
        let stale = recorded.filter { !sources.contains($0) }
        guard !stale.isEmpty else { return }
        try database.transaction { for source in stale { try database.execute("DELETE FROM sources WHERE source = ?", [.text(source)]) } }
    }

    /// Change fingerprints of fully indexed sources under `prefix`. A source
    /// whose fingerprint still matches needs no work on a rescan.
    public func sourceFingerprints(prefix: String) throws -> [String: String] {
        try ready()
        let rows = try database.rows("SELECT source, fingerprint FROM sources WHERE source LIKE ? ESCAPE '\\'", [.text(RetrievalDatabase.likePrefix(prefix))])
        var result: [String: String] = [:]
        for row in rows { if let source = row.text(0), let fingerprint = row.text(1) { result[source] = fingerprint } }
        return result
    }
    /// Call only after every segment of `source` was written.
    public func recordSource(_ source: String, fingerprint: String) throws {
        try ready()
        try database.execute("INSERT OR REPLACE INTO sources VALUES (?, ?)", [.text(source), .text(fingerprint)])
    }
    public func recordSources(_ fingerprints: [String: String]) throws {
        try ready()
        guard !fingerprints.isEmpty else { return }
        try database.transaction {
            for (source, fingerprint) in fingerprints { try database.execute("INSERT OR REPLACE INTO sources VALUES (?, ?)", [.text(source), .text(fingerprint)]) }
        }
    }

    public func count() throws -> Int { try ready(); return try database.strings("SELECT count(*) FROM segments", column: 0).first.flatMap(Int.init) ?? 0 }
    public func sourceCount() throws -> Int { try ready(); return try database.strings("SELECT count(DISTINCT source) FROM segments", column: 0).first.flatMap(Int.init) ?? 0 }

    /// Drops the in-memory vector table; the next query reloads it.
    public func releaseMemory() { table = nil }

    // MARK: Reading

    /// Hybrid lexical + semantic search. With `groupBySource` each source
    /// (a note, a book) contributes its best segment only; turn it off to
    /// get several passages of one book.
    /// `lexical: false` ranks by meaning alone and skips the keyword index —
    /// for callers that already have exact-word results of their own.
    public func search(_ query: String, vector: [Float]? = nil, limit: Int = 12, filter: RetrievalFilter = .all, groupBySource: Bool = true, lexical: Bool = true) throws -> [RetrievalHit] {
        try ready()
        let match = lexical ? LexicalForm.match(query) : nil
        guard match != nil || vector != nil, limit > 0 else { return [] }
        var lexicalRanks: [String: Int] = [:]
        if let match {
            let rows = try database.rows(
                "SELECT l.id, s.source FROM lexical l JOIN segments s ON s.id = l.id WHERE lexical MATCH ? ORDER BY bm25(lexical,0,2,1) LIMIT ?",
                [.text(match), .int(filter.isUnrestricted ? 100 : 1000)]
            )
            for row in rows {
                guard let id = row.text(0), let source = row.text(1), filter.admits(id: id, source: source) else { continue }
                lexicalRanks[id] = lexicalRanks.count
                if lexicalRanks.count == 100 { break }
            }
        }
        var semanticRanks: [String: Int] = [:]
        var semanticStrengths: [String: Float] = [:]
        if let vector, vector.count == TextEmbedder.dimensionValue {
            // Standardize within modality so no modality dominates solely from
            // its native cosine distribution, then fuse by rank.
            let table = try loadTable()
            let scores = table.scores(vector)
            var byModality: [RetrievalSegment.Modality: [(Int, Float)]] = [:]
            for row in 0..<table.count where filter.admits(id: table.ids[row], source: table.sources[row]) {
                byModality[table.modalities[row], default: []].append((row, scores[row]))
            }
            var standardized: [(Int, Float)] = []
            for group in byModality.values {
                let n = Float(group.count)
                let mean = group.reduce(Float(0)) { $0 + $1.1 } / n
                let deviation = max(0.01, (group.reduce(Float(0)) { $0 + pow($1.1 - mean, 2) } / n).squareRoot())
                standardized += group.map { ($0.0, ($0.1 - mean) / deviation) }
            }
            for (rank, entry) in Self.top(standardized, count: lexical ? max(200, limit * 4) : limit * 4).enumerated() {
                semanticRanks[table.ids[entry.0]] = rank
                semanticStrengths[table.ids[entry.0]] = entry.1
            }
        }
        let candidates = Set(lexicalRanks.keys).union(semanticRanks.keys)
        guard !candidates.isEmpty else { return [] }
        let segments = try load(Array(candidates))
        // Reciprocal-rank fusion is scale independent. Exact lookup gets a
        // separate stable boost; do not copy another app's BM25/cosine weights.
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var best: [String: RetrievalHit] = [:]
        for segment in segments {
            let lexical = lexicalRanks[segment.id].map { 1 / Float(20 + $0) } ?? 0
            let semantic = semanticRanks[segment.id].map { 1 / Float(20 + $0) } ?? 0
            let exact = !normalizedQuery.isEmpty && segment.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedQuery) ? Float(0.05) : 0
            let hit = RetrievalHit(
                segment: segment,
                score: lexical + semantic + exact,
                semanticStrength: semanticStrengths[segment.id]
            )
            let key = groupBySource ? segment.sourceID : segment.id
            if best[key].map({ $0.score < hit.score }) ?? true { best[key] = hit }
        }
        return Array(best.values.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Length-weighted mean of a source's segment vectors, renormalized —
    /// one vector per note for duplicate checks and neighbours. Nil when the
    /// source has no embedded segment, or its recorded fingerprint differs
    /// from `fingerprint` (when given).
    public func pooledVector(source: String, fingerprint: String? = nil) throws -> [Float]? {
        try ready()
        if let fingerprint {
            let recorded = try database.strings("SELECT fingerprint FROM sources WHERE source = ?", [.text(source)], column: 0).first
            guard recorded == fingerprint else { return nil }
        }
        let rows = try database.rows("SELECT payload, vector FROM segments WHERE source = ? AND vector IS NOT NULL", [.text(source)])
        var pooled = [Float](repeating: 0, count: TextEmbedder.dimensionValue)
        for row in rows {
            guard let blob = row.blob(1), let quantized = Quantized(data: blob) else { continue }
            let weight = Float(max(1, row.blob(0).flatMap { try? JSONDecoder().decode(RetrievalSegment.self, from: $0) }?.text.count ?? 1))
            let vector = quantized.floats
            for i in pooled.indices { pooled[i] += vector[i] * weight }
        }
        let norm = pooled.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        return pooled.map { $0 / norm }
    }

    /// Nearest segments to `source`'s pooled vector, by cosine alone.
    public func neighbors(of source: String, limit: Int = 8, filter: RetrievalFilter = .all) throws -> [RetrievalHit] {
        try ready()
        guard let vector = try pooledVector(source: source) else { return [] }
        var scoped = filter
        scoped.excludedSources.insert(source)
        let table = try loadTable()
        let scores = table.scores(vector)
        var ranked: [(Int, Float)] = []
        for row in 0..<table.count where scoped.admits(id: table.ids[row], source: table.sources[row]) { ranked.append((row, scores[row])) }
        // Over-fetch: several segments of one source collapse into one hit.
        let top = Self.top(ranked, count: limit * 4)
        let segments = Dictionary(uniqueKeysWithValues: try load(top.map { table.ids[$0.0] }).map { ($0.id, $0) })
        var seen = Set<String>(), hits: [RetrievalHit] = []
        for (row, score) in top {
            guard let segment = segments[table.ids[row]], seen.insert(segment.sourceID).inserted else { continue }
            hits.append(RetrievalHit(segment: segment, score: score))
            if hits.count == limit { break }
        }
        return hits
    }

    /// For each segment the `target` filter admits (at most `maxTargets`,
    /// evenly sampled), the cosine of the closest segment `comparison`
    /// admits. Lowest first: the passages nothing in the comparison set
    /// resembles — a chapter's parts no card covers yet.
    public func coverage(of target: RetrievalFilter, against comparison: RetrievalFilter, limit: Int = 6, maxTargets: Int = 400) throws -> [RetrievalCoverage] {
        try ready()
        let table = try loadTable()
        var targets = (0..<table.count).filter { target.admits(id: table.ids[$0], source: table.sources[$0]) }
        if targets.count > maxTargets {
            let step = Double(targets.count) / Double(maxTargets)
            targets = (0..<maxTargets).map { targets[Int(Double($0) * step)] }
        }
        guard !targets.isEmpty else { return [] }
        let others = (0..<table.count).filter { comparison.admits(id: table.ids[$0], source: table.sources[$0]) }
        let nearest = table.maxSimilarity(rows: targets, against: others)
        let ranked = zip(targets, nearest).sorted { $0.1 < $1.1 }.prefix(limit)
        let segments = Dictionary(uniqueKeysWithValues: try load(ranked.map { table.ids[$0.0] }).map { ($0.id, $0) })
        return ranked.compactMap { row, score in segments[table.ids[row]].map { RetrievalCoverage(segment: $0, nearest: score) } }
    }

    // MARK: Internals

    private func loadTable() throws -> VectorTable {
        if let table { return table }
        var loaded = VectorTable()
        for row in try database.rows("SELECT id, source, payload, vector FROM segments WHERE vector IS NOT NULL") {
            guard let id = row.text(0), let source = row.text(1), let blob = row.blob(3), let quantized = Quantized(data: blob) else { continue }
            loaded.set(id: id, source: source, modality: row.blob(2).flatMap(Self.modality(in:)) ?? .text, vector: quantized)
        }
        table = loaded
        return loaded
    }

    /// Reads `"modality":"…"` without decoding the whole payload.
    private static func modality(in payload: Data) -> RetrievalSegment.Modality? {
        struct Probe: Decodable { let modality: RetrievalSegment.Modality }
        return (try? JSONDecoder().decode(Probe.self, from: payload))?.modality
    }

    private func load(_ ids: [String]) throws -> [RetrievalSegment] {
        var result: [RetrievalSegment] = []
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min(ids.count, $0 + 400)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try database.rows("SELECT payload FROM segments WHERE id IN (\(marks))", chunk.map { .text($0) }) {
                if let payload = row.blob(0), let segment = try? JSONDecoder().decode(RetrievalSegment.self, from: payload) { result.append(segment) }
            }
        }
        return result
    }

    private static func top(_ entries: [(Int, Float)], count: Int) -> [(Int, Float)] {
        guard entries.count > count else { return entries.sorted { $0.1 > $1.1 } }
        // Partial selection: a threshold from a sorted sample would be
        // approximate; sorting a few tens of thousands of floats is cheap.
        return Array(entries.sorted { $0.1 > $1.1 }.prefix(count))
    }
}

enum RetrievalError: Error { case database(String), invalidVector }

// MARK: - Vectors

/// A normalized vector as int8 codes with one scale. Cosine error is about
/// 1e-3 — far below the gap between ranks that matter.
struct Quantized: Sendable {
    var codes: [Int8]
    var scale: Float
    init(_ vector: [Float]) {
        let peak = vector.reduce(Float(0)) { max($0, abs($1)) }
        scale = peak > 0 ? peak / 127 : 1
        let inverse = 1 / scale
        codes = vector.map { Int8(max(-127, min(127, ($0 * inverse).rounded()))) }
    }
    init?(data: Data) {
        guard data.count == TextEmbedder.dimensionValue + 4 else { return nil }
        scale = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        codes = data.dropFirst(4).map { Int8(bitPattern: $0) }
        guard scale.isFinite, scale > 0 else { return nil }
    }
    var data: Data {
        var data = withUnsafeBytes(of: scale) { Data($0) }
        data.append(contentsOf: codes.map { UInt8(bitPattern: $0) })
        return data
    }
    var floats: [Float] { codes.map { Float($0) * scale } }
}

/// Every embedded segment's vector in one row-major int8 matrix.
struct VectorTable: Sendable {
    private static let width = TextEmbedder.dimensionValue
    private static let block = 1024
    private(set) var ids: [String] = []
    private(set) var sources: [String] = []
    private(set) var modalities: [RetrievalSegment.Modality] = []
    private var codes: [Int8] = []
    private var scales: [Float] = []
    private var rowOf: [String: Int] = [:]
    var count: Int { ids.count }

    mutating func set(id: String, source: String, modality: RetrievalSegment.Modality, vector: Quantized) {
        if let row = rowOf[id] {
            sources[row] = source; modalities[row] = modality; scales[row] = vector.scale
            codes.replaceSubrange(row * Self.width..<(row + 1) * Self.width, with: vector.codes)
            return
        }
        rowOf[id] = ids.count
        ids.append(id); sources.append(source); modalities.append(modality); scales.append(vector.scale)
        codes.append(contentsOf: vector.codes)
    }

    mutating func remove(id: String) {
        guard let row = rowOf.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if row != last {
            ids[row] = ids[last]; sources[row] = sources[last]; modalities[row] = modalities[last]; scales[row] = scales[last]
            codes.replaceSubrange(row * Self.width..<(row + 1) * Self.width, with: codes[last * Self.width..<(last + 1) * Self.width])
            rowOf[ids[row]] = row
        }
        ids.removeLast(); sources.removeLast(); modalities.removeLast(); scales.removeLast()
        codes.removeLast(Self.width)
    }

    /// Cosine of `query` with every row, in row order.
    func scores(_ query: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        var floats = [Float](repeating: 0, count: Self.block * Self.width)
        for start in stride(from: 0, to: count, by: Self.block) {
            let rows = min(Self.block, count - start)
            convert(rows: start..<start + rows, into: &floats)
            result.withUnsafeMutableBufferPointer { out in
                floats.withUnsafeBufferPointer { matrix in
                    query.withUnsafeBufferPointer { vector in
                        unsafe vDSP_mmul(matrix.baseAddress!, 1, vector.baseAddress!, 1, out.baseAddress! + start, 1, vDSP_Length(rows), 1, vDSP_Length(Self.width))
                    }
                }
            }
        }
        for row in 0..<count { result[row] *= scales[row] }
        return result
    }

    /// For each of `rows`, the best cosine against any of `others`.
    func maxSimilarity(rows: [Int], against others: [Int]) -> [Float] {
        guard !others.isEmpty else { return Array(repeating: -1, count: rows.count) }
        let targets = rows.flatMap { row in codes[row * Self.width..<(row + 1) * Self.width].map { Float($0) * scales[row] } }
        var best = [Float](repeating: -.infinity, count: rows.count)
        var floats = [Float](repeating: 0, count: Self.block * Self.width)
        var product = [Float](repeating: 0, count: rows.count * Self.block)
        for start in stride(from: 0, to: others.count, by: Self.block) {
            let chunk = Array(others[start..<min(others.count, start + Self.block)])
            for (offset, row) in chunk.enumerated() {
                for i in 0..<Self.width { floats[offset * Self.width + i] = Float(codes[row * Self.width + i]) * scales[row] }
            }
            // targets (T×W) · chunkᵀ (W×C) = T×C. vDSP_mmult wants B as W×C,
            // so transpose the chunk first.
            var transposed = [Float](repeating: 0, count: Self.width * chunk.count)
            unsafe vDSP_mtrans(floats, 1, &transposed, 1, vDSP_Length(Self.width), vDSP_Length(chunk.count))
            unsafe vDSP_mmul(targets, 1, transposed, 1, &product, 1, vDSP_Length(rows.count), vDSP_Length(chunk.count), vDSP_Length(Self.width))
            for t in 0..<rows.count {
                for c in 0..<chunk.count where product[t * chunk.count + c] > best[t] { best[t] = product[t * chunk.count + c] }
            }
        }
        return best
    }

    private func convert(rows: Range<Int>, into floats: inout [Float]) {
        let count = rows.count * Self.width
        codes.withUnsafeBufferPointer { source in
            floats.withUnsafeMutableBufferPointer { target in
                unsafe vDSP_vflt8(source.baseAddress! + rows.lowerBound * Self.width, 1, target.baseAddress!, 1, vDSP_Length(count))
            }
        }
    }
}

// MARK: - Lexical form

/// FTS5's unicode61 tokenizer splits on spaces and punctuation, so a run of
/// Japanese or Chinese becomes one giant token that no query word matches.
/// Indexed text puts each Han, kana or CJK character in its own token, and a
/// CJK query word becomes a phrase of those characters — adjacent, in order.
enum LexicalForm {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FA1F: true
        default: false
        }
    }

    static func indexed(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isCJK) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { result.append(" "); result.append(scalar); result.append(" ") } else { result.append(scalar) }
        }
        return String(result)
    }

    /// An FTS5 MATCH expression of OR'ed quoted words, or nil when the query
    /// has none. Query syntax in the input is treated as plain text.
    static func match(_ query: String) -> String? {
        let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(20)
        guard !words.isEmpty else { return nil }
        return words.map { word in
            let tokens = indexed(word).split(separator: " ")
            return "\"" + tokens.joined(separator: " ") + "\""
        }.joined(separator: " OR ")
    }
}

// MARK: - SQLite

/// The owning actor is the sole caller. SQLite's FULLMUTEX mode additionally
/// guards its C handle; no handle or statement escapes this wrapper.
private final class RetrievalDatabase: @unchecked Sendable {
    enum Value { case text(String), int(Int), blob(Data), null }
    struct Row {
        fileprivate let values: [Any?]
        func text(_ column: Int) -> String? { values[column] as? String }
        func blob(_ column: Int) -> Data? { values[column] as? Data }
        func int(_ column: Int) -> Int? { values[column] as? Int }
    }
    private let db: OpaquePointer
    private let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        var handle: OpaquePointer?
        guard unsafe sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else { throw RetrievalError.database("Open failed") }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
    }
    deinit { sqlite3_close(db) }

    static func likePrefix(_ prefix: String) -> String {
        prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func statement(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard unsafe sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): unsafe sqlite3_bind_text(statement, position, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, position, Int64(number))
            case .blob(let data): _ = unsafe data.withUnsafeBytes { unsafe sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }
    func execute(_ sql: String, _ bindings: [Value] = []) throws {
        let statement = try statement(sql, bindings); defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
    }
    func rows(_ sql: String, _ bindings: [Value] = []) throws -> [Row] {
        let statement = try statement(sql, bindings); defer { sqlite3_finalize(statement) }
        var result: [Row] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var values: [Any?] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT: values.append(unsafe sqlite3_column_text(statement, column).map { unsafe String(cString: $0) })
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values.append(unsafe sqlite3_column_blob(statement, column).map { unsafe Data(bytes: $0, count: count) } ?? Data())
                default: values.append(nil)
                }
            }
            result.append(Row(values: values))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw RetrievalError.database(String(cString: sqlite3_errmsg(db))) }
        return result
    }
    func strings(_ sql: String, _ bindings: [Value] = [], column: Int) throws -> [String] {
        try rows(sql, bindings).compactMap { row in row.text(column) ?? row.int(column).map(String.init) }
    }
    func blobs(_ sql: String) throws -> [Data] { try rows(sql).compactMap { $0.blob(0) } }
}
