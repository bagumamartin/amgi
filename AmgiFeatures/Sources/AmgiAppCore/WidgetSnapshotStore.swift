import Foundation

public enum WidgetSnapshotStore {
    /// The app group shared by the app, the widget extension, and
    /// AmgiTheme's defaults. Canonical definition — AmgiTheme cannot see
    /// AmgiAppCore, so it reads this through AppGroup below.
    public static let groupId = AppGroup.identifier

    public static func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = fileURL(deckId: snapshot.deckId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func read(deckId: Int64) -> WidgetSnapshot? {
        guard let url = fileURL(deckId: deckId) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func read(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Copies snapshots from historical app groups after the Ijuka rebrand.
    /// Current files always win, so this is safe to run on every launch.
    public static func migrateLegacySnapshotsIfNeeded() {
        guard let destination = container() else { return }
        let fm = FileManager.default
        for groupID in AppGroup.legacyIdentifiers {
            guard let source = container(groupID: groupID) else { continue }
            let files = (try? fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.lastPathComponent.hasPrefix("widget-snapshot-")
                && file.pathExtension == "json" {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try? fm.copyItem(at: file, to: target)
            }
        }
    }

    /// Removes every snapshot file. Used only at a collection/profile
    /// boundary, before the first snapshot for the new collection is written.
    public static func removeAllSnapshots() {
        guard let container = container() else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in files
        where url.lastPathComponent.hasPrefix("widget-snapshot-") && url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes every snapshot file whose deckId is not in `keep`.
    public static func removeSnapshots(notIn keep: Set<Int64>) {
        guard let container = container() else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in files
        where url.lastPathComponent.hasPrefix("widget-snapshot-") && url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
                .dropFirst("widget-snapshot-".count)
            if Int64(stem).map(keep.contains) != true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Enumerates all snapshot files to build the deck list for the widget picker.
    public static func allSnapshots() -> [WidgetSnapshot] {
        guard let container = container() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("widget-snapshot-") && $0.pathExtension == "json" }
            .compactMap { read(from: $0) }
            .sorted { $0.deckName < $1.deckName }
    }
}

private extension WidgetSnapshotStore {
    static func container(groupID: String = groupId) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func fileURL(deckId: Int64) -> URL? {
        container()?.appendingPathComponent("widget-snapshot-\(deckId).json")
    }
}
