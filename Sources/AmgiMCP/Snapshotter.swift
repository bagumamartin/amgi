import Foundation

/// File-level backup of `collection.anki2` before destructive tool calls.
///
/// Copies the database together with its `-wal`/`-shm` sidecars rather
/// than using SQLite's online-backup API: rslib keeps long-lived read
/// state on its own connection, which makes `backup_step`/`VACUUM INTO`
/// contend on SQLITE_BUSY indefinitely. A trio copy has the same
/// guarantee that matters here — committed transactions live either in
/// the base file or the WAL, and SQLite replays the WAL on open — so
/// the snapshot restores to exactly the pre-mutation state.
///
/// This only ever runs while this process owns the collection lock
/// (the app holding it fails the tool call earlier), so there is no
/// concurrent writer to race against.
enum Snapshotter {
    private static let keep = 5

    enum SnapshotError: LocalizedError {
        case missingDatabase(String)

        var errorDescription: String? {
            switch self {
            case .missingDatabase(let path): return "snapshot source missing: \(path)"
            }
        }
    }

    /// Copies db + sidecars into a timestamped snapshot directory.
    /// Returns the copied database path on success.
    @discardableResult
    static func snapshot(collectionPath: String, profileDirectory: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: collectionPath) else {
            throw SnapshotError.missingDatabase(collectionPath)
        }
        let backupsDir = profileDirectory.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970)
        let destDir = backupsDir.appendingPathComponent("pre-destructive-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let baseName = URL(fileURLWithPath: collectionPath).lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let src = collectionPath + suffix
            guard fm.fileExists(atPath: src) else { continue }
            let dst = destDir.appendingPathComponent(baseName + suffix).path
            try fm.copyItem(atPath: src, toPath: dst)
        }

        pruneOldSnapshots(in: backupsDir)
        return destDir.appendingPathComponent(baseName)
    }

    private static func pruneOldSnapshots(in directory: URL) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let snapshots = dirs
            .filter { $0.lastPathComponent.hasPrefix("pre-destructive-") }
            .sorted {
                let lhsDate = modificationDate(of: $0)
                let rhsDate = modificationDate(of: $1)
                return lhsDate > rhsDate
            }
        for stale in snapshots.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate {
            return date
        }
        return .distantPast
    }
}
