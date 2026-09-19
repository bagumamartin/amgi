public import Foundation

/// Creates restorable file snapshots while the caller holds the collection
/// engine's exclusive access lock. Copies the SQLite database together with
/// its WAL and shared-memory sidecars so committed WAL transactions remain
/// recoverable.
public enum CollectionSnapshotter {
    private static let keep = 5

    public enum SnapshotError: LocalizedError {
        case missingDatabase(String)

        public var errorDescription: String? {
            switch self {
            case .missingDatabase(let path): "snapshot source missing: \(path)"
            }
        }
    }

    @discardableResult
    public static func snapshot(collectionPath: String, profileDirectory: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: collectionPath) else {
            throw SnapshotError.missingDatabase(collectionPath)
        }
        let backupsDir = profileDirectory.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let destDir = backupsDir.appendingPathComponent(
            "pre-destructive-\(stamp)-\(nonce)", isDirectory: true
        )
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let baseName = URL(fileURLWithPath: collectionPath).lastPathComponent
        do {
            for suffix in ["", "-wal", "-shm"] {
                let source = collectionPath + suffix
                guard fm.fileExists(atPath: source) else { continue }
                try fm.copyItem(
                    atPath: source,
                    toPath: destDir.appendingPathComponent(baseName + suffix).path
                )
            }
        } catch {
            try? fm.removeItem(at: destDir)
            throw error
        }

        pruneOldSnapshots(in: backupsDir)
        return destDir.appendingPathComponent(baseName)
    }

    private static func pruneOldSnapshots(in directory: URL) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let snapshots = directories
            .filter { $0.lastPathComponent.hasPrefix("pre-destructive-") }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
        for stale in snapshots.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
