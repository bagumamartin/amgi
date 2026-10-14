import Foundation
import AmgiEmbeddings
import PhosphorSwift

/// Semantic deck-icon suggestion using the installed EmbeddingGemma 2 catalog.
///
/// Tag descriptions and queries use the same installed, normalized Q8 model.
public actor IconSuggester {
    public static let shared = IconSuggester()

    /// Conservative initial floor; retrieval acceptance requires our own
    /// multilingual deck-title fixtures before calibrating this threshold.
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
            let entries = try await catalog()

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
            let entries = try await catalog()
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


    private struct CatalogCache: Codable {
        var identity: String
        var vectors: [String: [Float]]
    }
    private var preparation: Task<Void, Never>?
    private static var catalogURL: URL {
        ModelAssetManager.modelsRootURL.appendingPathComponent("icon-catalog-768.json")
    }
    /// Old E5 vectors are never read. Build the full tag catalog using the same
    /// installed Q8 engine, checkpointing periodically for interrupted runs.
    public func prepareCatalog() {
        guard preparation == nil, ModelAssetManager.isModelInstalled else { return }
        preparation = Task(priority: .utility) { [weak self] in await self?.buildCatalog() }
    }
    private func catalog() async throws -> [Entry] {
        if let catalogEntries { return catalogEntries }
        if let data = try? Data(contentsOf: Self.catalogURL),
           let cache = try? JSONDecoder().decode(CatalogCache.self, from: data), cache.identity == TextEmbedder.modelIdentity,
           let tagsURL = Bundle.module.url(forResource: "IconTags", withExtension: "json"),
           let tags = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: tagsURL)),
           cache.vectors.count == tags.count,
           cache.vectors.values.allSatisfy({ $0.count == TextEmbedder.dimensionValue && $0.allSatisfy(\.isFinite) }) {
            let entries = cache.vectors.map { Entry(name: $0.key, vector: $0.value) }.sorted { $0.name < $1.name }
            catalogEntries = entries; return entries
        }
        prepareCatalog()
        throw IconSuggesterError.emptyCatalog
    }
    private func buildCatalog() async {
        defer { preparation = nil }
        guard let tagsURL = Bundle.module.url(forResource: "IconTags", withExtension: "json"),
              let tags = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: tagsURL)) else { return }
        var cache = (try? Data(contentsOf: Self.catalogURL)).flatMap { try? JSONDecoder().decode(CatalogCache.self, from: $0) }
            ?? CatalogCache(identity: TextEmbedder.modelIdentity, vectors: [:])
        if cache.identity != TextEmbedder.modelIdentity { cache = CatalogCache(identity: TextEmbedder.modelIdentity, vectors: [:]) }
        do {
            for (name, text) in tags.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                while ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { try await Task.sleep(for: .seconds(2)) }
                if cache.vectors[name]?.count == TextEmbedder.dimensionValue { continue }
                cache.vectors[name] = try await embedder.embed(text, prefix: .passage)
                if cache.vectors.count % 25 == 0 { try JSONEncoder().encode(cache).write(to: Self.catalogURL, options: .atomic) }
                await Task.yield()
            }
            try JSONEncoder().encode(cache).write(to: Self.catalogURL, options: .atomic)
            catalogEntries = cache.vectors.map { Entry(name: $0.key, vector: $0.value) }.sorted { $0.name < $1.name }
        } catch { logEngineFailure(error) }
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
        case .missingEmbeddingsResource: "Icon tag descriptions not found in bundle"
        case .emptyCatalog: "Icon embedding catalog is empty"
        }
    }
}
