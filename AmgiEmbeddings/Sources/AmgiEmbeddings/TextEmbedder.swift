import CoreML
import Foundation
import Tokenizers

/// Generic multilingual-e5-small text embedder shared by icon suggestion
/// AND Browse semantic search (browse-redesign-spec D4 / §4.6).
///
/// Owns the one resident CoreML engine (fp16, 384-dim L2-normalized
/// output) plus tokenizer; callers choose the e5 task prefix:
/// `"query: "` for searches, `"passage: "` for corpus documents. Using
/// matching prefixes matters for retrieval quality.
public actor TextEmbedder {
    public static let shared = TextEmbedder()

    public enum Prefix: String, Sendable {
        case query = "query: "
        case passage = "passage: "
    }

    private let sequenceLength = 256
    private let dimension = 384

    private struct Engine {
        var tokenizer: any Tokenizer
        var model: MLModel
        var inputIDs: MLMultiArray
        var attentionMask: MLMultiArray
        var padID: Int32
    }

    private var engine: Engine?
    private var engineError: (any Error)?
    /// Memoized vectors keyed by already-prefixed text.
    private var vectorCache: [String: [Float]] = [:]

    public init() {}

    public static var dimensionValue: Int { 384 }

    /// Embeds one text; throws if the bundled model is unavailable.
    public func embed(_ text: String, prefix: Prefix) async throws -> [Float] {
        let key = prefix.rawValue + text
        if let cached = vectorCache[key] { return cached }

        let loaded = try await engineIfNeeded()
        var vector = try run(text, prefix: prefix, into: loaded)
        normalize(&vector)
        if vectorCache.count > 1024 { vectorCache.removeAll(keepingCapacity: true) }
        vectorCache[key] = vector
        return vector
    }

    // MARK: - Engine lifecycle

    private func engineIfNeeded() async throws -> Engine {
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
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: await compiledModelURL(), configuration: config)

        guard let folder = Self.tokenizerFolderURL else {
            throw EmbedderError.missingTokenizerResources
        }
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)

        let shape: [NSNumber] = [1, NSNumber(value: sequenceLength)]
        return Engine(
            tokenizer: tokenizer,
            model: model,
            inputIDs: try MLMultiArray(shape: shape, dataType: .int32),
            attentionMask: try MLMultiArray(shape: shape, dataType: .int32),
            padID: Int32(tokenizer.convertTokenToId("<pad>") ?? 1)
        )
    }

    private func run(_ text: String, prefix: Prefix, into engine: Engine) throws -> [Float] {
        var ids = engine.tokenizer.encode(text: prefix.rawValue + text)
        ids.truncateForInference(maxLength: sequenceLength)
        // Capture BEFORE padding: the attention mask must cover only the
        // real tokens, not the pad fill (icon-pipeline lesson).
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
        else { throw EmbedderError.unexpectedModelOutput }

        var vector = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension { vector[i] = multiArray[i].floatValue }
        return vector
    }

    // MARK: - Resources (CDN-installed model, dev-machine bundle fallback)

    /// Lookup order: (1) CDN-installed model in Application Support (the
    /// production path — ModelAssetManager downloads + compiles it on first
    /// launch); (2) precompiled copy in the package bundle (dev machines that
    /// still build one locally); (3) raw `.mlpackage` in the bundle compiled
    /// to Caches (legacy dev path). Absence throws and every caller degrades
    /// (name-token icons, no semantic fallback) until the download lands.
    private func compiledModelURL() async throws -> URL {
        if let installed = ModelAssetManager.installedCompiledModelURL(),
           FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }

        if let precompiled = Bundle.module.url(
            forResource: "MultilingualE5Small", withExtension: "mlmodelc"
        ) { return precompiled }

        guard let package = Bundle.module.url(
            forResource: "MultilingualE5Small", withExtension: "mlpackage"
        ) else { throw EmbedderError.missingModelResource }

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
        let compiled = try await MLModel.compileModel(at: package)
        _ = try? fm.replaceItemAt(destination, withItemAt: compiled)
        return destination
    }

    /// Called by `ModelAssetManager` after a fresh install: engine load
    /// failures are memoized in `engineError`, so without this reset an embed
    /// attempted before the download finished would keep throwing forever.
    public func resetEngineForModelInstall() {
        engine = nil
        engineError = nil
        vectorCache.removeAll(keepingCapacity: true)
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

    // MARK: - Math

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(lhs.count, rhs.count) { sum += lhs[i] * rhs[i] }
        return sum
    }

    private func normalize(_ vector: inout [Float]) {
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

enum EmbedderError: LocalizedError {
    case missingModelResource
    case missingTokenizerResources
    case unexpectedModelOutput

    var errorDescription: String? {
        switch self {
        case .missingModelResource: "e5 model not installed yet — background download pending"
        case .missingTokenizerResources: "tokenizer resources not found in bundle"
        case .unexpectedModelOutput: "CoreML model produced unexpected output"
        }
    }
}

private extension Array where Element == Int {
    mutating func truncateForInference(maxLength: Int) {
        guard count > maxLength else { return }
        self = Array(self.prefix(maxLength))
    }
}
