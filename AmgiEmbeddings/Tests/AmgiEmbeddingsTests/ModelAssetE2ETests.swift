import Foundation
import Testing
@testable import AmgiEmbeddings

private var e2eEnabled: Bool {
    ProcessInfo.processInfo.environment["AMGI_E2E_MODEL_DOWNLOAD"] != nil
}

/// Runs `work` with the model store redirected into a fresh temp directory
/// (see ModelStoreTestSupport — the host machine's real install is never
/// touched and no 200MB residue survives the suite).
private func withIsolatedStore<T: Sendable>(
    _ work: @Sendable (ModelAssetManager) async throws -> T
) async throws -> T {
    try await ModelStoreTestSupport.withIsolatedStore(work)
}

/// Live-network verification of the full CDN pipeline (manifest → download →
/// verify → unzip → compile → embed). Gated behind
/// `AMGI_E2E_MODEL_DOWNLOAD=1` so normal `swift test` stays offline-safe.
/// Serialized: both tests share the on-disk install location and must not
/// race each other.
@Suite(
    "ModelAssetE2E",
    .serialized,
    .enabled(if: e2eEnabled, "Set AMGI_E2E_MODEL_DOWNLOAD=1 to run the live CDN test")
)
struct ModelAssetE2ETests {
    @Test("Live CDN download installs a working model", .timeLimit(.minutes(25)))
    func liveDownload() async throws {
        try await withIsolatedStore { manager in
            await manager.ensureModelAvailable()
            let status = await manager.status
            guard case .ready(let version) = status else {
                Issue.record("expected ready, got \(status)")
                return
            }
            #expect(version >= 1)
            // Full stack: installed model + bundled tokenizer produce a vector.
            let vector = try await TextEmbedder.shared.embed("e2e smoke test", prefix: .query)
            #expect(vector.count == TextEmbedder.dimensionValue)
            await TextEmbedder.shared.resetEngineForModelInstall()
        }
    }

    @Test("Cancel stops an in-flight download and leaves neutral state")
    func cancelDownload() async throws {
        try await withIsolatedStore { manager in
            // Fresh instance isolates status from the shared singleton.
            let job = Task { await manager.ensureModelAvailable() }
        // Wait for bytes to flow (or fail fast if offline / already done).
        // Poll tightly and cancel on first sight: a fixed sleep would race
        // fast networks (the 206MB fetch can finish in seconds).
        var sawDownloading = false
        for _ in 0..<600 {
            let current = await manager.status
            if case .downloading = current { sawDownloading = true; break }
            if case .ready = current { break }
            if case .failed = current { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if case .ready = await manager.status {
            // Model already installed — nothing to cancel; vacuous pass.
            await job.value
            return
        }
        guard sawDownloading else {
            Issue.record("download never started — offline?")
            await job.value
            return
        }
        await manager.cancelDownload()
        await job.value
        #expect(await manager.status == .notInstalled)
        }
    }
}

private struct DigUpReference: Decodable { let vectors: [String: [Float]] }
extension ModelAssetE2ETests {
    @Test("Native Q8 text, image, audio and video/mixed graph gates", .enabled(if: ProcessInfo.processInfo.environment["AMGI_E2E_MEDIA"] == "1"), .timeLimit(.minutes(25)))
    func allModalitiesReference() async throws {
        try await withIsolatedStore { manager in
            for module in ModelAssetManager.Module.allCases { await manager.install(module, allowExpensiveNetwork: true) }
            for module in ModelAssetManager.Module.allCases { #expect(ModelAssetManager.isInstalled(module)) }
            guard ModelAssetManager.Module.allCases.allSatisfy(ModelAssetManager.isInstalled) else {
                Issue.record("Native modules did not install: \(await manager.status)"); return
            }
            let folder = try #require(Bundle.module.url(forResource: "DigUpReference", withExtension: nil))
            let reference = try JSONDecoder().decode(DigUpReference.self, from: Data(contentsOf: folder.appendingPathComponent("vectors.json")))
            let encoder = TextEmbedder.shared
            let queries = [("query", "payment declined error"), ("query-bn", "ইলিশ মাছ রান্না"), ("query-ar", "متى تغلق المكتبة")]
            for (name, query) in queries {
                let actual = try await encoder.embed(query, prefix: .query)
                let expected = try #require(reference.vectors[name])
                let score = TextEmbedder.cosine(actual, expected)
                print("GEMMA_GATE \(name): \(score)")
                #expect(score > 0.995, "Q8 cross-runtime text agreement")
            }
            let documents = [
                ("document", "title: Tokyo itinerary | text: Flight to Tokyo Haneda on November 3. Then the train to Kamakura to see the Great Buddha, and back for dinner in Shibuya."),
                ("document-long", "title: none | text: " + (1...60).map { "Note \($0): the review moved to room \($0 % 7 + 2) because the projector in the main hall failed again, and the team agreed to send the slides the night before." }.joined(separator: " ")),
            ]
            for (name, document) in documents {
                let actual = try await encoder.embedMixed([.text(document)])
                let expected = try #require(reference.vectors[name])
                let score = TextEmbedder.cosine(actual, expected)
                print("GEMMA_GATE \(name): \(score)")
                #expect(score > 0.995)
            }
            for (name, file, budget) in [("screen-280", "screen.png", 280), ("photo-140", "photo.jpg", 140), ("frame-70", "photo.jpg", 70)] {
                let actual = try await encoder.embedImage(folder.appendingPathComponent(file), maxSoftTokens: budget)
                let expected = try #require(reference.vectors[name])
                let score = TextEmbedder.cosine(actual, expected)
                print("GEMMA_GATE \(name): \(score)")
                #expect(score > 0.99, "Cross-runtime preprocessing and vector agreement")
            }
            let index = try RetrievalIndex(url: ModelAssetManager.modelsRootURL.appendingPathComponent("fixture.sqlite"))
            let media = MediaIndexer(index: index, cache: ModelAssetManager.modelsRootURL.appendingPathComponent("previews"))
            try await media.indexFile(folder.appendingPathComponent("speech.wav"), sourceID: "audio:fixture", title: "Synthetic speech")
            let hits = try await index.search("Synthetic speech")
            let audio = try #require(hits.first?.segment.vector)
            let audioScore = TextEmbedder.cosine(audio, try #require(reference.vectors["speech"]))
            print("GEMMA_GATE speech: \(audioScore)")
            #expect(audioScore > 0.99)
            #expect(hits.first?.segment.anchor.hasPrefix("time:0.0-") == true)
            let frame = try await encoder.embedMixed([.videoFrame(folder.appendingPathComponent("photo.jpg"), timestamp: nil)])
            #expect(TextEmbedder.cosine(frame, try #require(reference.vectors["frame-70"])) > 0.99)
            let plain = try await encoder.embed("receptor antagonist", prefix: .passage)
            let mixedText = try await encoder.embedMixed([.text("title: none | text: receptor antagonist")])
            #expect(TextEmbedder.cosine(plain, mixedText) > 0.9999)
            let ordered = try await encoder.embedMixed([.text("A screenshot showing a payment problem"), .image(folder.appendingPathComponent("screen.png"))])
            let reverse = try await encoder.embedMixed([.image(folder.appendingPathComponent("screen.png")), .text("A screenshot showing a payment problem")])
            #expect(ordered.count == 768 && ordered.allSatisfy(\.isFinite))
            #expect(reverse.count == 768 && reverse.allSatisfy(\.isFinite))
            #expect(ordered != reverse, "Ordered inputs must not be replaced by vector averaging")
            await encoder.resetEngineForModelInstall()
        }
    }
}
