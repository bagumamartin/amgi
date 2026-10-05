import AmgiReader
import Foundation
import Testing
@testable import AnkiClients

/// The iCloud Drive progress mirror: per-profile manifests, last-write-wins
/// per book, and a stale push that never regresses a newer position.
@Suite("Reader progress iCloud mirror")
struct ReaderProgressICloudStoreTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func payload(
        chapterID: Int64 = 3,
        progress: Double = 0.4,
        at epochSeconds: TimeInterval
    ) -> ReaderSavedProgress {
        ReaderSavedProgress(
            chapterID: chapterID,
            progress: progress,
            updatedAt: Date(timeIntervalSince1970: epochSeconds)
        )
    }

    @Test("push and load round-trip, isolated per profile")
    func roundTripIsProfileScoped() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = payload(at: 1_700_000_000)
        let manifest = try await ReaderProgressICloudStore.pushBookProgress(
            profileID: "alice",
            bookID: "pdf-abc",
            payload: saved,
            overrideRoot: root
        )
        #expect(manifest.entries["pdf-abc"] == saved)

        let loaded = await ReaderProgressICloudStore.loadManifest(
            profileID: "alice",
            overrideRoot: root
        )
        #expect(loaded?.entries["pdf-abc"] == saved)

        // Another profile sees nothing: positions must never leak across
        // profiles through the shared container.
        #expect(await ReaderProgressICloudStore.loadManifest(
            profileID: "bob",
            overrideRoot: root
        ) == nil)
    }

    @Test("a stale push never overwrites a newer position")
    func stalePushIsANoOp() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let newer = payload(chapterID: 5, progress: 0.8, at: 1_700_000_100)
        _ = try await ReaderProgressICloudStore.pushBookProgress(
            profileID: "alice",
            bookID: "pdf-abc",
            payload: newer,
            overrideRoot: root
        )
        let afterStale = try await ReaderProgressICloudStore.pushBookProgress(
            profileID: "alice",
            bookID: "pdf-abc",
            payload: payload(chapterID: 2, progress: 0.1, at: 1_700_000_000),
            overrideRoot: root
        )
        #expect(afterStale.entries["pdf-abc"] == newer)
    }

    @Test("merging keeps the newest position per book from each side")
    func mergeKeepsNewestPerBook() {
        let left = ReaderProgressManifest(entries: [
            "keep-left": payload(progress: 0.2, at: 1_700_000_100),
            "contested": payload(progress: 0.3, at: 1_700_000_000),
        ])
        let right = ReaderProgressManifest(entries: [
            "keep-right": payload(progress: 0.5, at: 1_700_000_000),
            "contested": payload(progress: 0.9, at: 1_700_000_200),
        ])
        let merged = ReaderProgressICloudStore.merge(left, right)
        #expect(merged.entries["keep-left"]?.progress == 0.2)
        #expect(merged.entries["keep-right"]?.progress == 0.5)
        #expect(merged.entries["contested"]?.progress == 0.9)
    }
}
