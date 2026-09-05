import Foundation
import AmgiEmbeddings
import PhosphorSwift

/// Semantic deck-icon suggestion over the bundled Phosphor tag embeddings.
///
/// Pipeline: text → `"query: "`-prefixed e5-small embedding (CoreML via
/// ``TextEmbedder``) → dot-product scan against the pre-normalized
/// `IconEmbeddings.json` catalog (cosine similarity = plain dot product).
public actor IconSuggester {
    public static let shared = IconSuggester()

    /// Below this top-1 cosine score the suggester distrusts the semantic
    /// result and falls back to icon-name token matching.
    ///
    /// Calibrated empirically (2026-08) over realistic deck names: e5-small
    /// similarities compress into a narrow ~0.82–0.88 band across the whole
    /// catalog — even nonsense input ("Random junk xyzzy") scores ≥0.84, so
    /// the spec's original 0.75 floor never fires. 0.80 catches only
    /// genuinely poor matches while keeping weak-but-relevant hits (e.g.
    /// cross-lingual queries at ~0.82).
    public static let confidenceThreshold: Float = 0.80

    /// Ultimate fallback when nothing else resolves.
    public static let defaultIconName = "book"

    public struct Match: Equatable, Sendable {
        public var iconName: String
        public var score: Float
    }

    private struct Entry {
        var name: String
        var vector: [Float]
    }

    /// Model+tokenizer live in TextEmbedder (shared with Browse semantic
    /// search so only ONE copy of the resident engine exists).
    private let embedder = TextEmbedder.shared

    /// Catalog vectors, loaded lazily on first use.
    private var catalogEntries: [Entry]?
    private var catalogError: (any Error)?

    public init() {}

    // MARK: - Public API

    /// Top semantic match for a deck name. Never returns nil — garbage or
    /// low-confidence input degrades to name-token matching and finally to
    /// ``defaultIconName``.
    public func bestMatch(for deckName: String) async -> String {
        await bestMatchResult(for: deckName).iconName
    }

    /// Top match plus its cosine score (exposed for tests/debug).
    public func bestMatchResult(for deckName: String) async -> Match {
        let trimmed = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Match(iconName: Self.defaultIconName, score: 0)
        }

        do {
            let queryVector = try await embedder.embed(trimmed, prefix: .query)
            let entries = try catalog()

            var bestIndex = -1
            var bestScore: Float = -1
            for (index, entry) in entries.enumerated() {
                let score = TextEmbedder.cosine(queryVector, entry.vector)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            // Low confidence — don't trust an arbitrary semantic winner.
            if bestScore < Self.confidenceThreshold,
               let fallback = Ph.bestByNameToken(in: trimmed) {
                return Match(iconName: fallback.amgiCaseName, score: bestScore)
            }
            guard bestIndex >= 0 else {
                return Match(iconName: Self.defaultIconName, score: 0)
            }
            return Match(iconName: entries[bestIndex].name, score: bestScore)
        } catch {
            logEngineFailure(error)
            if let fallback = Ph.bestByNameToken(in: trimmed) {
                return Match(iconName: fallback.amgiCaseName, score: 0)
            }
            return Match(iconName: Self.defaultIconName, score: 0)
        }
    }

    /// Ranked search over the icon catalog. Empty query → the full list in
    /// catalog order (browse mode; the picker layers its own curated view
    /// on top of this).
    public func search(_ query: String, topK: Int = 20) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, topK > 0 else {
            return Ph.allCases.map(\.amgiCaseName)
        }

        do {
            let queryVector = try await embedder.embed(trimmed, prefix: .query)
            let entries = try catalog()
            var scored = entries.map { ($0.name, TextEmbedder.cosine(queryVector, $0.vector)) }
            scored.sort { $0.1 > $1.1 }
            return Array(scored.prefix(topK).map(\.0))
        } catch {
            logEngineFailure(error)
            // Degrade to substring filtering so the picker still works.
            let folded = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil
            )
            return Ph.allCases
                .filter { $0.amgiCaseName.lowercased().contains(folded.lowercased()) }
                .map(\.amgiCaseName)
        }
    }

    // MARK: - Catalog

    private func catalog() throws -> [Entry] {
        if let error = catalogError { throw error }
        if let catalogEntries { return catalogEntries }
        do {
            let loaded = try Self.loadEntries()
            guard !loaded.isEmpty else { throw IconSuggesterError.emptyCatalog }
            catalogError = nil
            catalogEntries = loaded
            return loaded
        } catch {
            catalogError = error
            throw error
        }
    }

    private static func loadEntries() throws -> [Entry] {
        guard let url = Bundle.module.url(forResource: "IconEmbeddings", withExtension: "json") else {
            throw IconSuggesterError.missingEmbeddingsResource
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String: [Float]].self, from: data)
        return decoded
            .compactMap { name, vector in
                guard vector.count == 384 else { return nil }
                var v = vector
                normalize(&v)
                return Entry(name: name, vector: v)
            }
            .sorted { $0.name < $1.name }
    }

    private static func normalize(_ vector: inout [Float]) {
        var sum: Float = 0
        for v in vector { sum += v * v }
        let norm = sum.squareRoot()
        guard norm > 0 else { return }
        for i in vector.indices { vector[i] /= norm }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<lhs.count { sum += lhs[i] * rhs[i] }
        return sum
    }

    private func logEngineFailure(_ error: any Error) {
        #if DEBUG
        print("[IconSuggester] engine unavailable: \(error)")
        #endif
    }
}

// MARK: - Errors

enum IconSuggesterError: LocalizedError {
    case missingEmbeddingsResource
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .missingEmbeddingsResource: "IconEmbeddings.json not found in bundle"
        case .emptyCatalog: "Icon embedding catalog is empty"
        }
    }
}
