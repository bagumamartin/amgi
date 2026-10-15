import AmgiReader
import Foundation

/// iCloud Drive mirror for the library's collections, beside the reading
/// progress manifest and under the same rules:
/// ```
/// <container>/Library/ReaderCollections/{profileID}/collections.json
/// ```
/// One `ReaderCollectionTree` per profile. Every write is read-merge-write
/// through `ReaderCollectionTree.merged`, which keeps the newer copy of each
/// collection and each book's placement, so two devices editing between
/// syncs both keep their changes and converge on the same tree.
enum ReaderCollectionsICloudStore {
    private static let directoryName = "ReaderCollections"
    private static let fileName = "collections.json"
    private static let writeSerializer = WriteSerializer()

    private actor WriteSerializer {
        func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
            try await work()
        }
    }

    static func url(profileID: String, overrideRoot: URL? = nil) -> URL? {
        guard let container = ReaderICloudConfiguration.containerURL(overrideRoot: overrideRoot) else {
            return nil
        }
        return ReaderICloudConfiguration.privateURL(directoryName, in: container)
            .appendingPathComponent(ReaderProgressICloudStore.sanitized(profileID), isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The cloud tree, or nil when iCloud is unavailable, nothing has synced
    /// yet, or the file cannot be read. Never throws: the local tree is
    /// always enough to show the library.
    static func load(profileID: String, overrideRoot: URL? = nil) async -> ReaderCollectionTree? {
        guard let url = url(profileID: profileID, overrideRoot: overrideRoot),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try await ReaderProgressICloudStore.ensureDownloaded(at: url, acceptingLocalCopy: true)
        } catch {
            return nil
        }
        guard let data = ReaderProgressICloudStore.coordinatedRead(at: url),
              let tree = try? decode(data) else { return nil }
        return resolveConflicts(at: url, current: tree)
    }

    /// Merges `tree` into the cloud copy and returns the result. Throws when
    /// iCloud is unavailable or the existing file cannot be downloaded — the
    /// caller simply pushes again on the next change or launch, since the
    /// local tree already holds everything.
    @discardableResult
    static func push(
        _ tree: ReaderCollectionTree,
        profileID: String,
        overrideRoot: URL? = nil
    ) async throws -> ReaderCollectionTree {
        guard let url = url(profileID: profileID, overrideRoot: overrideRoot) else {
            throw ReaderProgressICloudError.containerUnavailable
        }
        return try await writeSerializer.run {
            var merged = tree
            if FileManager.default.fileExists(atPath: url.path) {
                // Overwriting a placeholder that never downloaded would drop
                // every other device's changes: that is a retry-later.
                try await ReaderProgressICloudStore.ensureDownloaded(at: url)
                if let data = ReaderProgressICloudStore.coordinatedRead(at: url),
                   let existing = try? decode(data) {
                    merged = ReaderCollectionTree.merged(existing, tree)
                    if merged == existing { return resolveConflicts(at: url, current: merged) }
                }
            }
            try ReaderProgressICloudStore.coordinatedWrite(encode(merged), to: url)
            return resolveConflicts(at: url, current: merged)
        }
    }

    /// Folds unresolved iCloud file conflicts in. Two devices writing between
    /// syncs is ordinary, and the tree merge keeps both sides' changes.
    @discardableResult
    private static func resolveConflicts(at url: URL, current: ReaderCollectionTree) -> ReaderCollectionTree {
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return current }
        var merged = current
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url), let other = try? decode(data) {
                merged = ReaderCollectionTree.merged(merged, other)
            }
            version.isResolved = true
        }
        if let data = try? encode(merged) {
            try? ReaderProgressICloudStore.coordinatedWrite(data, to: url)
        }
        return merged
    }

    /// Dates keep Foundation's own encoding, which round-trips exactly. A
    /// millisecond encoding would trim each timestamp, so a tree read back
    /// would never equal the one written and every launch would push again.
    static func decode(_ data: Data) throws -> ReaderCollectionTree {
        try JSONDecoder().decode(ReaderCollectionTree.self, from: data)
    }

    static func encode(_ tree: ReaderCollectionTree) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tree)
    }
}
