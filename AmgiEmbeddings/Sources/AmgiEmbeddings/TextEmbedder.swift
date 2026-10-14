import EmbeddingGemma2
import Foundation

/// One serial native MLX runtime shared by retrieval, duplicate checks and icons.
/// Q8 weights, BF16 activations (audio weights BF16), normalized Float32 outputs.
public actor TextEmbedder {
    public static let shared = TextEmbedder()
    public enum Prefix: String, Sendable { case query, passage }
    public enum Input: Sendable {
        case text(String), image(URL), audio(samples: [Float]), videoFrame(URL, timestamp: TimeInterval?)
    }
    private var engine: TextEncoder?
    private var loading: Task<TextEncoder, any Error>?
    private var idleUnload: Task<Void, Never>?
    private var vectorCache: [String: [Float]] = [:]
    private var visionLoaded = false
    private var audioLoaded = false
    private var activeForwards = 0
    private var isResetting = false
    public init() {}
    public static var dimensionValue: Int { 768 }
    public static var modelIdentity: String { ModelAssetManager.modelIdentity }
    public func memoryDiagnostics() async -> [String: Int] { await engine?.memory() ?? [:] }

    public func embed(_ text: String, prefix: Prefix) async throws -> [Float] {
        guard !isResetting else { throw CancellationError() }
        activeForwards += 1
        defer { activeForwards -= 1 }
        let key = prefix.rawValue + ":" + text
        if let value = vectorCache[key] { return value }
        let loaded = try await engineIfNeeded()
        try Task.checkCancellation()
        let vector = try await loaded.encode([text], task: prefix == .query ? .search : .document)[0]
        try validate(vector)
        if vectorCache.count >= 256 { vectorCache.removeAll(keepingCapacity: true) }
        vectorCache[key] = vector
        scheduleUnload()
        return vector
    }
    public func embedImage(_ url: URL, maxSoftTokens: Int = 280) async throws -> [Float] {
        guard !isResetting else { throw CancellationError() }
        activeForwards += 1
        defer { activeForwards -= 1 }
        let loaded = try await engineIfNeeded()
        try await enableVision(loaded)
        let result = try await loaded.encodeImage(url: url, maxSoftTokens: maxSoftTokens)
        try validate(result); scheduleUnload(); return result
    }
    public func embedAudio(samples: [Float]) async throws -> [Float] {
        guard !isResetting else { throw CancellationError() }
        activeForwards += 1
        defer { activeForwards -= 1 }
        let loaded = try await engineIfNeeded()
        try await enableAudio(loaded)
        let result = try await loaded.encodeAudio(AudioProcessor.prepare(samples: samples))
        try validate(result); scheduleUnload(); return result
    }
    /// Joint contextual forward, preserving input order. Never averages vectors.
    /// Each audio part must be a bounded 16 kHz mono window (at most 30 seconds).
    public func embedMixed(_ inputs: [Input]) async throws -> [Float] {
        guard !isResetting else { throw CancellationError() }
        activeForwards += 1
        defer { activeForwards -= 1 }
        let loaded = try await engineIfNeeded()
        var parts: [EmbeddingInput] = []
        for input in inputs {
            try Task.checkCancellation()
            switch input {
            case .text(let text): parts.append(.text(text))
            case .image(let url): try await enableVision(loaded); parts.append(.image(try ImageProcessor.prepare(RGBImage.load(url))))
            case .videoFrame(let url, let timestamp):
                try await enableVision(loaded)
                parts.append(.videoFrame(try ImageProcessor.prepare(RGBImage.load(url), maxSoftTokens: 70), timestamp: timestamp))
            case .audio(let samples): try await enableAudio(loaded); parts.append(.audio(try AudioProcessor.prepare(samples: samples)))
            }
        }
        let result = try await loaded.encodeMixed(parts)
        try validate(result); scheduleUnload(); return result
    }
    private func enableVision(_ loaded: TextEncoder) async throws {
        guard ModelAssetManager.isInstalled(.vision) else { throw EmbedderError.moduleNotInstalled("Image") }
        if !visionLoaded { try await loaded.enableVision(directory: ModelAssetManager.directory(for: .vision)); visionLoaded = true }
    }
    private func enableAudio(_ loaded: TextEncoder) async throws {
        guard ModelAssetManager.isInstalled(.audio) else { throw EmbedderError.moduleNotInstalled("Audio") }
        if !audioLoaded { try await loaded.enableAudio(directory: ModelAssetManager.directory(for: .audio)); audioLoaded = true }
    }
    private func engineIfNeeded() async throws -> TextEncoder {
        idleUnload?.cancel()
        if let engine { return engine }
        guard ModelAssetManager.isModelInstalled else { throw EmbedderError.missingModelResource }
        if let loading { return try await loading.value }
        let task = Task { try await TextEncoder(directory: ModelAssetManager.directory(for: .text)) }
        loading = task
        defer { loading = nil }
        let result = try await task.value
        guard !isResetting else { throw CancellationError() }
        engine = result; return result
    }
    private func scheduleUnload() {
        idleUnload?.cancel()
        idleUnload = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)); await self?.resetEngineForModelInstall() } catch {}
        }
    }
    public func resetEngineForModelInstall() async {
        guard !isResetting else { return }
        isResetting = true
        idleUnload?.cancel(); idleUnload = nil
        loading?.cancel()
        while activeForwards > 0 { await Task.yield() }
        await engine?.clearTransientCache()
        loading = nil; engine = nil
        visionLoaded = false; audioLoaded = false; vectorCache.removeAll(keepingCapacity: false)
        isResetting = false
    }
    private func validate(_ vector: [Float]) throws {
        guard vector.count == Self.dimensionValue, vector.allSatisfy(\.isFinite) else { throw EmbedderError.unexpectedModelOutput }
    }
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == dimensionValue, rhs.count == dimensionValue,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return -.infinity }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

enum EmbedderError: LocalizedError {
    case missingModelResource, unexpectedModelOutput, moduleNotInstalled(String)
    var errorDescription: String? {
        switch self {
        case .missingModelResource: "Download the EmbeddingGemma 2 text model to enable semantic retrieval."
        case .moduleNotInstalled(let name): "Download the \(name.lowercased()) retrieval module in Settings first."
        case .unexpectedModelOutput: "The embedding model produced invalid output."
        }
    }
}
