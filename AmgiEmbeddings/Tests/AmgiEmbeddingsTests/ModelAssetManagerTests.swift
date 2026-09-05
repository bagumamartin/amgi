import Foundation
import Testing
@testable import AmgiEmbeddings

/// CDN contract + install-state consistency for the e5 weight download.
/// Never touches the network: the manifest sample mirrors the live endpoint,
/// and the state assertions hold with or without an installed model.
@Suite("ModelAssetManager")
struct ModelAssetManagerTests {
    // Mirrors https://amgiassets.bagumamartin.com/manifest.json (v1).
    private let sampleManifest = """
        {
          "version": 1,
          "url": "models/e5-small-coreml/1/MultilingualE5Small.mlpackage.zip",
          "sha256": "f339314e01c7206505b54164b5479ff737bd03e299e199cf2a7a7b57dbd8d043",
          "byteSize": 216411873
        }
        """

    @Test("Manifest decodes the CDN format")
    func manifestDecodes() throws {
        let manifest = try JSONDecoder().decode(
            ModelAssetManager.RemoteManifest.self,
            from: Data(sampleManifest.utf8)
        )
        #expect(manifest.version == 1)
        #expect(manifest.url.hasSuffix(".mlpackage.zip"))
        #expect(manifest.sha256.count == 64)
        #expect(manifest.byteSize > 200_000_000)
    }

    @Test("Relative archive URL resolves against the manifest endpoint")
    func relativeURLResolves() async throws {
        let manager = ModelAssetManager()
        let manifest = try JSONDecoder().decode(
            ModelAssetManager.RemoteManifest.self,
            from: Data(sampleManifest.utf8)
        )
        let resolved = try await manager.archiveURL(for: manifest)
        #expect(resolved.absoluteString == "https://amgiassets.bagumamartin.com/models/e5-small-coreml/1/MultilingualE5Small.mlpackage.zip")
    }

    @Test("Absolute archive URL passes through untouched")
    func absoluteURLPassesThrough() async throws {
        let manager = ModelAssetManager(
            manifestURL: URL(string: "https://example.com/other/manifest.json")!
        )
        let manifest = ModelAssetManager.RemoteManifest(
            version: 2,
            url: "https://cdn.example.com/m/model.zip",
            sha256: String(repeating: "0", count: 64),
            byteSize: 1
        )
        let resolved = try await manager.archiveURL(for: manifest)
        #expect(resolved.absoluteString == "https://cdn.example.com/m/model.zip")
    }

    @Test("Install-state accessors agree with each other")
    func installStateConsistent() async {
        // Serialized against isolated suites: the real-store reading is only
        // valid when no override is active.
        await ModelStoreTestSupport.withRealStore {
            #expect(ModelAssetManager.isModelInstalled == (ModelAssetManager.installedCompiledModelURL() != nil))
            if let version = ModelAssetManager.installedVersion() {
                #expect(ModelAssetManager.installedCompiledModelURL()?.lastPathComponent == "MultilingualE5Small.mlmodelc")
                #expect(version > 0)
            }
        }
    }

    @Test("Store override isolates tests from the real install")
    func storeOverrideIsolates() async {
        await ModelStoreTestSupport.withRealStore {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("amgi-store-override-\(UUID().uuidString)", isDirectory: true)
            ModelAssetManager.modelsRootOverride = scratch
            defer {
                ModelAssetManager.modelsRootOverride = nil
                try? FileManager.default.removeItem(at: scratch)
            }
            // A nonexistent scratch dir reads as "nothing installed" even when
            // the real group container holds a model.
            #expect(ModelAssetManager.installedVersion() == nil)
            #expect(!ModelAssetManager.isModelInstalled)
            #expect(ModelAssetManager.modelsRootURL == scratch)
        }
    }

    @Test("Unentitled processes fall back to sandbox Application Support")
    func groupFallback() {
        // `swift test` carries no app-group entitlement, so containerURL is
        // nil here: the store must resolve to the sandbox fallback, never
        // crash, and never claim the group path it cannot reach.
        if ModelAssetManager.groupContainerModelsRoot() != nil {
            // Entitled host (e.g. running inside the app process) — the
            // group root is correct and covered by integration runs.
            #expect(ModelAssetManager.modelsRootURL.path.hasSuffix("AmgiEmbeddings/models"))
        } else {
            let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AmgiEmbeddings", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
            #expect(ModelAssetManager.modelsRootURL == fallback)
        }
    }
}
