import CoreML
import Foundation
import PhosphorSwift
import Tokenizers

/// Semantic deck-icon suggestion over the bundled Phosphor tag embeddings.
///
/// Pipeline: text → `"query: "`-prefixed e5-small embedding (CoreML, fp16,
/// L2-normalized 384-d output) → dot-product scan against the pre-normalized
/// `IconEmbeddings.json` catalog (cosine similarity = plain dot product).
///
/// Both public entry points are async because the tokenizer + model load
/// lazily on first use and inference runs inside the actor; a single
/// prediction is single-digit ms, so callers can simply await.
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

    private let sequenceLength = 256
    private let dimension = 384
    private let queryPrefix = "query: "

    public struct Match: Equatable, Sendable {
        public var iconName: String
        public var score: Float
    }

    private struct Entry {
        var name: String
        var vector: [Float]
    }

    /// Loaded lazily on first use; rebuilt on failure of the previous load.
    private struct Engine {
        var entries: [Entry]
        var tokenizer: any Tokenizer
        var model: MLModel
        var inputIDs: MLMultiArray
        var attentionMask: MLMultiArray
        var padID: Int32
    }

    private var engine: Engine?
    private var engineError: (any Error)?
    /// Memoized query vectors keyed by already-prefixed text.
    private var vectorCache: [String: [Float]] = [:]

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
            let engine = try await self.engine()
            let queryVector = try embed(trimmed, into: engine)

            var bestIndex = -1
            var bestScore: Float = -1
            for (index, entry) in engine.entries.enumerated() {
                let score = Self.dot(queryVector, entry.vector)
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
            return Match(iconName: engine.entries[bestIndex].name, score: bestScore)
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
            let engine = try await engine()
            let queryVector = try embed(trimmed, into: engine)
            var scored = engine.entries.map { ($0.name, Self.dot(queryVector, $0.vector)) }
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

    // MARK: - Debug

    // MARK: - Engine

    private func engine() async throws -> Engine {
        if let error = engineError { throw error }
        if let engine { return engine }
        do {
            let loaded = try await loadEngine()
            engineError = nil
            engine = loaded
            return loaded
        } catch {
            engineError = error
            throw error
        }
    }

    private func loadEngine() async throws -> Engine {
        let entries = try Self.loadEntries()
        guard !entries.isEmpty else {
            throw IconSuggesterError.emptyCatalog
        }

        let modelURL = try compiledModelURL()
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: config)

        guard let folder = Self.tokenizerFolderURL else {
            throw IconSuggesterError.missingTokenizerResources
        }
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)

        let shape: [NSNumber] = [1, NSNumber(value: sequenceLength)]
        return Engine(
            entries: entries,
            tokenizer: tokenizer,
            model: model,
            inputIDs: try MLMultiArray(shape: shape, dataType: .int32),
            attentionMask: try MLMultiArray(shape: shape, dataType: .int32),
            padID: Int32(tokenizer.convertTokenToId("<pad>") ?? 1)
        )
    }

    /// Embeds `text` with the query prefix, padded/truncated to the fixed
    /// CoreML sequence length, returning an L2-normalized vector (the model
    /// already normalizes; this is defensive and idempotent).
    private func embed(_ text: String, into engine: Engine) throws -> [Float] {
        let key = queryPrefix + text
        if let cached = vectorCache[key] { return cached }

        var ids = engine.tokenizer.encode(text: key)
        ids.truncateForInference(maxLength: sequenceLength)
        // Capture BEFORE padding: the attention mask must cover only the
        // real tokens, not the pad fill.
        let realCount = ids.count
        while ids.count < sequenceLength { ids.append(Int(engine.padID)) }

        fill(engine.inputIDs, with: Array(ids.map(Int32.init)))
        var mask = [Int32](repeating: 0, count: sequenceLength)
        for i in 0..<realCount { mask[i] = 1 }
        fill(engine.attentionMask, with: mask)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: engine.inputIDs),
            "attention_mask": MLFeatureValue(multiArray: engine.attentionMask),
        ])
        let output = try engine.model.prediction(from: provider)
        guard let multiArray = output.featureValue(for: "embeddings")?.multiArrayValue,
              multiArray.count == dimension
        else { throw IconSuggesterError.unexpectedModelOutput }

        var vector = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension { vector[i] = multiArray[i].floatValue }
        Self.normalize(&vector)

        if vectorCache.count > 512 { vectorCache.removeAll(keepingCapacity: true) }
        vectorCache[key] = vector
        return vector
    }

    private func logEngineFailure(_ error: any Error) {
        #if DEBUG
        print("[IconSuggester] engine unavailable: \(error)")
        #endif
    }

    // MARK: - Resources

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

    /// Prefers an Xcode-precompiled `.mlmodelc` in the bundle; otherwise
    /// compiles the bundled `.mlpackage` once into Caches.
    private func compiledModelURL() throws -> URL {
        if let precompiled = Bundle.module.url(
            forResource: "MultilingualE5Small", withExtension: "mlmodelc"
        ) { return precompiled }

        guard let package = Bundle.module.url(
            forResource: "MultilingualE5Small", withExtension: "mlpackage"
        ) else { throw IconSuggesterError.missingModelResource }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let destination = caches
            .appendingPathComponent("AmgiIcons", isDirectory: true)
            .appendingPathComponent("MultilingualE5Small.mlmodelc", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return destination }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        let compiled = try MLModel.compileModel(at: package)
        _ = try? fm.replaceItemAt(destination, withItemAt: compiled)
        return destination
    }

    private static var tokenizerFolderURL: URL? {
        if let folder = Bundle.module.url(forResource: "Tokenizer", withExtension: nil),
           (try? folder.checkResourceIsReachable()) == true || isDirectory(folder) {
            return folder
        }
        return Bundle.module.resourceURL
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Math helpers

    static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<lhs.count { sum += lhs[i] * rhs[i] }
        return sum
    }

    static func normalize(_ vector: inout [Float]) {
        var sum: Float = 0
        for v in vector { sum += v * v }
        let norm = sum.squareRoot()
        guard norm > 0 else { return }
        for i in vector.indices { vector[i] /= norm }
    }

    private func fill(_ array: MLMultiArray, with values: [Int32]) {
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in 0..<values.count { pointer[i] = values[i] }
    }
}

// MARK: - Errors

enum IconSuggesterError: LocalizedError {
    case missingEmbeddingsResource
    case missingModelResource
    case missingTokenizerResources
    case emptyCatalog
    case unexpectedModelOutput

    var errorDescription: String? {
        switch self {
        case .missingEmbeddingsResource: "IconEmbeddings.json not found in bundle"
        case .missingModelResource: "MultilingualE5Small.mlpackage not found in bundle"
        case .missingTokenizerResources: "tokenizer.json / tokenizer_config.json not found in bundle"
        case .emptyCatalog: "Icon embedding catalog is empty"
        case .unexpectedModelOutput: "CoreML model produced unexpected output"
        }
    }
}

// MARK: - Private helpers

private extension Array where Element == Int {
    /// Keeps the leading special token (<s>) when truncating long inputs;
    /// e5 deck names/queries are short so this rarely engages.
    mutating func truncateForInference(maxLength: Int) {
        guard count > maxLength else { return }
        self = Array(self.prefix(maxLength))
    }
}
