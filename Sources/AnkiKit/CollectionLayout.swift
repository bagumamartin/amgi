public import Foundation

/// Canonical on-disk layout of an Amgi profile's collection directory.
///
/// Shared by the app (`AccountStore`), the watch app, and the `amgi-mcp`
/// helper so every process resolves the same files.
///
/// Root resolution order (macOS matters most here):
///   1. `AMGI_COLLECTION_ROOT` override — tests and power users.
///   2. **App Group container** — the CANONICAL Mac root. The app is
///      sandboxed (its own Application Support lives inside a container
///      the unsandboxed helper can't reach), while agents spawn the
///      helper outside any sandbox. The group container is writable by
///      both, so engine data, `mcp.json`, and the IPC socket all live
///      under one roof.
///   3. Legacy roots (sandbox container / home Application Support) —
///      kept as read sources for one-time migration into the group
///      root, never written after that.
///
/// On iOS/watchOS the plain Application Support layout is unchanged
/// (each platform's sandbox IS the single owner).
public enum CollectionLayout {
    /// The macOS app-group identifier as it appears on disk (Team ID
    /// prefixed — see project.yml's APP_GROUP_IDENTIFIER note).
    private static let macGroupContainerName =
        "39557WW39R.group.com.bagumamartin.AmgiApp"

    /// Root directory holding one subdirectory per profile.
    public static func rootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if os(macOS)
        if let override = environment["AMGI_COLLECTION_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let fm = FileManager.default
        let groupRoot = macGroupAnkiCollectionRoot()
        // Ensure the canonical root exists so fresh installs and the
        // helper agree from the very first run.
        try? fm.createDirectory(at: groupRoot, withIntermediateDirectories: true)
        return groupRoot
        #else
        return legacyApplicationSupportRoot(environment: environment)
        #endif
    }

    /// Existing data roots worth migrating INTO the canonical root,
    /// oldest last. Empty on non-Mac platforms.
    public static func legacyMacRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        #if os(macOS)
        var roots: [URL] = []
        let fm = FileManager.default
        if let override = environment["AMGI_COLLECTION_ROOT"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        // Sandboxed app's own Application Support.
        // The calling process's own sandbox container (the app case):
        // NSHomeDirectory() inside a sandbox IS the container Data dir.
        let ownContainer = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/AnkiCollection",
                                    isDirectory: true)
        if fm.fileExists(atPath: ownContainer.path) { roots.append(ownContainer) }
        roots.append(legacyApplicationSupportRoot(environment: environment))
        return roots
        #else
        return []
        #endif
    }

    /// Per-profile collection directory. Files inside follow Anki's
    /// layout: `collection.anki2`, `media/`, `media.db`.
    public static func profileDirectory(
        for profileID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        rootDirectory(environment: environment)
            .appendingPathComponent(profileID, isDirectory: true)
    }

    public static func collectionPath(
        for profileID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        profileDirectory(for: profileID, environment: environment)
            .appendingPathComponent("collection.anki2").path
    }

    public static func mediaFolderPath(
        for profileID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        profileDirectory(for: profileID, environment: environment)
            .appendingPathComponent("media", isDirectory: true).path
    }

    public static func mediaDbPath(
        for profileID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        profileDirectory(for: profileID, environment: environment)
            .appendingPathComponent("media.db").path
    }

    // MARK: - Plumbing

    private static func legacyApplicationSupportRoot(
        environment: [String: String]
    ) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("AnkiCollection", isDirectory: true)
    }


    private static let macGroupID = "group.com.bagumamartin.AmgiApp"
    private static let macGroupOnDiskName =
        "39557WW39R.group.com.bagumamartin.AmgiApp"

    /// Canonical Mac root: <group container>/AnkiCollection.
    ///
    /// The ENTITLED app must use FileManager.containerURL — the sandbox
    /// grants write access to exactly the directory it resolves (the
    /// Team-ID-prefixed on-disk form), not to reconstructed paths. The
    /// unsandboxed helper falls back to the stable on-disk locations.
    public static func macGroupAnkiCollectionRoot() -> URL {
        let fm = FileManager.default
        if let groupDir = fm.containerURL(
            forSecurityApplicationGroupIdentifier: macGroupID
        ) {
            return groupDir.appendingPathComponent("AnkiCollection", isDirectory: true)
        }

        let groupContainers = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
        // Match containerURL's on-disk convention first, but prefer any
        // variant that already holds migrated data.
        let candidates = [
            groupContainers.appendingPathComponent(macGroupID, isDirectory: true),
            groupContainers.appendingPathComponent(macGroupOnDiskName, isDirectory: true),
        ]
        for candidate in candidates {
            let root = candidate.appendingPathComponent("AnkiCollection", isDirectory: true)
            if fm.fileExists(atPath: root.appendingPathComponent("default").path) {
                return root
            }
        }
        for candidate in candidates
        where fm.fileExists(atPath: candidate.path) {
            return candidate.appendingPathComponent("AnkiCollection", isDirectory: true)
        }
        return candidates[0].appendingPathComponent("AnkiCollection", isDirectory: true)
    }

    /// One-time convergence: move any profile data found in legacy Mac
    /// roots into the canonical group root. Canonical wins on conflict;
    /// idempotent, safe to call from multiple processes. Skipped when an
    /// explicit AMGI_COLLECTION_ROOT override is active.
    public static func migrateIntoCanonicalRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if os(macOS)
        guard environment["AMGI_COLLECTION_ROOT"] == nil else { return }
        let fm = FileManager.default
        let canonical = rootDirectory(environment: environment)

        var sources = legacyMacRoots(environment: environment)
        // The sandboxed app's own Application Support is NOT visible via
        // the constructed-home variant and vice versa; include both forms.
        sources.append(
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/AnkiCollection",
                                        isDirectory: true)
        )

        for legacy in sources {
            let std = legacy.standardizedFileURL.path
            if std == canonical.standardizedFileURL.path { continue }
            guard fm.fileExists(atPath: legacy.path) else { continue }
            let entries = (try? fm.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: nil
            )) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let dest = canonical.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                do {
                    try fm.moveItem(at: entry, to: dest)
                } catch {
                    try? fm.copyItem(at: entry, to: dest)
                }
            }
        }
        #endif
    }
}
