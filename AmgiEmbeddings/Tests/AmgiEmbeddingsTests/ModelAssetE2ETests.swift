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
