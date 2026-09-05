import Foundation
import Testing
@testable import AmgiEmbeddings

/// Serializes every test that touches `ModelAssetManager` store state.
/// Swift Testing runs suites in parallel in one process, and the store root
/// is process-global mutable state (`modelsRootOverride`) — without this
/// serializer an E2E download in one suite would land in another suite's
/// scratch dir (or the real Application Support). Actor isolation provides
/// the mutual exclusion with no locks held across awaits; test-only, never
/// production.
enum ModelStoreTestSupport {
    private actor Serializer {
        func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
            try await work()
        }
    }

    private static let serializer = Serializer()

    /// Runs `work` with the store redirected into a fresh temp directory,
    /// then deletes it, clears the override, and drops any cached engine —
    /// the host machine's real install is never touched.
    static func withIsolatedStore<T: Sendable>(
        _ work: @Sendable (ModelAssetManager) async throws -> T
    ) async throws -> T {
        try await serializer.run {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("amgi-e2e-\(UUID().uuidString)", isDirectory: true)
            ModelAssetManager.modelsRootOverride = scratch
            defer {
                ModelAssetManager.modelsRootOverride = nil
                try? FileManager.default.removeItem(at: scratch)
            }
            do {
                return try await work(ModelAssetManager())
            } catch {
                await TextEmbedder.shared.resetEngineForModelInstall()
                throw error
            }
        }
    }

    /// Runs `work` against the real store, excluding isolated suites.
    static func withRealStore<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        try await serializer.run(work)
    }
}
