import AmgiReader
import Foundation
import Testing
@testable import AnkiClients

/// The iCloud Drive mirror for library collections: a push merges into
/// what other devices wrote rather than replacing it.
@Suite("Reader collections iCloud mirror")
struct ReaderCollectionsICloudStoreTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-collections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("two devices' pushes merge, and profiles stay apart")
    func pushesMerge() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var phone = ReaderCollectionTree()
        let physics = phone.createCollection(named: "Physics", in: nil)
        phone.move(.book("b1"), to: physics)
        try await ReaderCollectionsICloudStore.push(phone, profileID: "alice", overrideRoot: root)

        var pad = ReaderCollectionTree()
        let poetry = pad.createCollection(named: "Poetry", in: nil)
        let merged = try await ReaderCollectionsICloudStore.push(pad, profileID: "alice", overrideRoot: root)

        #expect(merged.collection(physics) != nil)
        #expect(merged.collection(poetry) != nil)
        #expect(merged.parent(of: .book("b1")) == physics)

        let loaded = await ReaderCollectionsICloudStore.load(profileID: "alice", overrideRoot: root)
        #expect(loaded == merged)
        #expect(await ReaderCollectionsICloudStore.load(profileID: "bob", overrideRoot: root) == nil)
    }
}
