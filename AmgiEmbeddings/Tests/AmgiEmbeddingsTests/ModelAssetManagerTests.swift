import CryptoKit
import Foundation
import Testing
@testable import AmgiEmbeddings

@Suite("Pinned Gemma 2 assets", .serialized)
struct ModelAssetManagerTests {
    @Test func pinnedManifestCoversEveryModule() throws {
        let manifest = try ModelAssetManager.bundledManifest()
        for module in ModelAssetManager.Module.allCases {
            let files = manifest.files.filter { $0.key.hasPrefix(module.rawValue + "/") }
            #expect(!files.isEmpty)
            #expect(files.values.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 })
        }
        #expect(ModelAssetManager.modelIdentity.contains("768"))
        #expect(ModelAssetManager.modelIdentity.contains("audio-bf16"))
    }
    @Test func fileVerificationRejectsCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("verified bytes".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: url)
        let file = ModelAssetManager.Manifest.File(bytes: Int64(data.count), sha256: digest)
        try ModelAssetManager.verify(url, file: file)
        try Data("corrupt bytes!".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ModelAssetManager.verify(url, file: file) }
    }
    @Test func legacyE5IsNeverAnInstalledGemmaModel() async throws {
        try await ModelStoreTestSupport.withRealStore {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ModelAssetManager.modelsRootOverride = scratch
            defer { ModelAssetManager.modelsRootOverride = nil; try? FileManager.default.removeItem(at: scratch) }
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent("v1/MultilingualE5Small.mlmodelc"), withIntermediateDirectories: true)
            #expect(!ModelAssetManager.isModelInstalled)
            #expect(ModelAssetManager.installedVersion() == nil)
        }
    }
    @Test func invalidVectorCannotBeCompared() {
        #expect(TextEmbedder.cosine(Array(repeating: 1, count: 384), Array(repeating: 1, count: 768)) == -.infinity)
    }
}
