import AmgiReader
import Foundation

/// Failures from the iCloud Drive progress mirror. The local
/// `ReaderProgressStore` remains the source of truth, so every failure here
/// degrades to "sync later" (push) or "use local positions" (load) — the
/// library never breaks because iCloud is unavailable.
enum ReaderProgressICloudError: Error, Sendable {
    /// No iCloud account / container for this device. Pushes stay pending and
    /// are retried on later launches; loads fall back to local positions.
    case containerUnavailable
    /// A placeholder that could not materialize within the download window.
    /// Treated as retry-later on push so a slow network cannot clobber the
    /// cloud manifest with a partial view of it.
    case downloadTimedOut
}

/// iCloud Drive mirror for per-book reading progress.
///
/// Layout under `<container>/Documents/ReaderProgress/`:
/// ```
/// {profileID}/manifest.json
/// ```
///
/// One manifest per profile, each a `ReaderProgressManifest` mapping book ID
/// to its latest payload. Merges are last-write-wins per book — the same rule
/// the library already applies between local and cloud — so convergence
/// depends on which position is newest, never on which device wrote last.
///
/// This is what keeps book data off the Anki backend: positions reach the
/// user's other devices through the app's iCloud Drive container, while Anki
/// notes (including cards made from books) continue through AnkiWeb. The two
/// never mix, so reading a book no longer dirties the collection or triggers
/// an Anki sync on its own.
enum ReaderProgressICloudStore {
    private static let directoryName = "ReaderProgress"
    private static let manifestFileName = "manifest.json"

    /// Serializes read-modify-write cycles in this process. Safety across
    /// processes and devices comes from `NSFileCoordinator` plus per-book
    /// last-write-wins merging, so a concurrent writer can never silently
    /// drop another device's newer position.
    private static let writeSerializer = ManifestWriteSerializer()

    private actor ManifestWriteSerializer {
        func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
            try await work()
        }
    }

    // MARK: - Paths

    static func manifestURL(profileID: String, overrideRoot: URL? = nil) -> URL? {
        let base: URL
        if let overrideRoot {
            base = overrideRoot
        } else if FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(
                      forUbiquityContainerIdentifier: ReaderICloudConfiguration.defaultContainerIdentifier
                  ) {
            base = container
        } else {
            return nil
        }
        return base
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(sanitized(profileID), isDirectory: true)
            .appendingPathComponent(manifestFileName)
    }

    // MARK: - Reads

    /// The cloud manifest, or nil when iCloud is unavailable, nothing has
    /// synced yet, or the file cannot be read. Never throws: callers treat
    /// "no cloud state" and "unreadable cloud state" identically and fall
    /// back to local positions.
    static func loadManifest(
        profileID: String,
        overrideRoot: URL? = nil
    ) async -> ReaderProgressManifest? {
        guard let url = manifestURL(profileID: profileID, overrideRoot: overrideRoot) else {
            return nil
        }
        // Best effort: a placeholder that cannot materialize (offline, slow
        // network) must not stall the library — local positions still load.
        do {
            try await ensureDownloaded(at: url)
        } catch {
            return nil
        }
        guard let data = coordinatedRead(at: url),
              let manifest = try? decode(data) else {
            return nil
        }
        return resolveConflicts(at: url, current: manifest)
    }

    // MARK: - Writes

    /// Merges one book's payload into the cloud manifest and returns the
    /// result. Throws when iCloud is unavailable or the merge cannot land —
    /// the caller records a pending push and retries on a later launch, so a
    /// failed mirror never loses the local position it was mirroring.
    @discardableResult
    static func pushBookProgress(
        profileID: String,
        bookID: String,
        payload: ReaderSavedProgress,
        overrideRoot: URL? = nil
    ) async throws -> ReaderProgressManifest {
        guard let url = manifestURL(profileID: profileID, overrideRoot: overrideRoot) else {
            throw ReaderProgressICloudError.containerUnavailable
        }
        return try await writeSerializer.run {
            try await pushToCloud(url: url, bookID: bookID, payload: payload)
        }
    }

    private static func pushToCloud(
        url: URL,
        bookID: String,
        payload: ReaderSavedProgress
    ) async throws -> ReaderProgressManifest {
        var manifest = ReaderProgressManifest()
        if FileManager.default.fileExists(atPath: url.path) {
            // The file exists but its contents are not here yet: overwriting
            // the placeholder with a single-entry manifest would drop every
            // other book's position, so a download that cannot complete is a
            // retry-later rather than a write-now.
            try await ensureDownloaded(at: url)
            if let data = coordinatedRead(at: url),
               let decoded = try? decode(data) {
                manifest = decoded
            } else {
                // Present but unreadable (a torn write from a crashed device):
                // self-heal by replacing it with a manifest holding this book
                // rather than poisoning every future push with the same failure.
                let fresh = ReaderProgressManifest(entries: [bookID: payload])
                try coordinatedWrite(fresh, to: url)
                return fresh
            }
        }
        // Idempotent on stale or identical writes: pushing an older payload
        // over a newer one is a no-op, not a regression.
        if let existing = manifest.entries[bookID],
           existing.updatedAt > payload.updatedAt {
            return manifest
        }
        manifest.entries[bookID] = payload
        try coordinatedWrite(manifest, to: url)
        return resolveConflicts(at: url, current: manifest)
    }

    // MARK: - Merging

    /// Last-write-wins per book. Shared by conflict resolution and the push
    /// path so every merge in the system applies the same rule.
    static func merge(
        _ left: ReaderProgressManifest,
        _ right: ReaderProgressManifest
    ) -> ReaderProgressManifest {
        var out = left
        for (id, payload) in right.entries {
            if let existing = out.entries[id], existing.updatedAt > payload.updatedAt {
                continue
            }
            out.entries[id] = payload
        }
        out.version = max(left.version, right.version)
        return out
    }

    /// Folds any unresolved iCloud file conflicts into the manifest. Two
    /// devices writing between syncs is ordinary, not an error: each side's
    /// file holds newer positions for different books, and per-book merging
    /// keeps both.
    @discardableResult
    static func resolveConflicts(
        at url: URL,
        current: ReaderProgressManifest
    ) -> ReaderProgressManifest {
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return current }
        var merged = current
        var resolvedAny = false
        for version in conflicts {
            guard let data = try? Data(contentsOf: version.url),
                  let other = try? decode(data) else { continue }
            merged = merge(merged, other)
            version.isResolved = true
            resolvedAny = true
        }
        if resolvedAny {
            try? coordinatedWrite(merged, to: url)
        }
        return merged
    }

    // MARK: - Coding

    static func decode(_ data: Data) throws -> ReaderProgressManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let manifest = try? decoder.decode(ReaderProgressManifest.self, from: data) {
            return manifest
        }
        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        return try legacyDecoder.decode(ReaderProgressManifest.self, from: data)
    }

    // MARK: - File plumbing

    private static func coordinatedRead(at url: URL) -> Data? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var data: Data?
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinated in
            data = try? Data(contentsOf: coordinated)
        }
        guard coordinationError == nil else { return nil }
        return data
    }

    private static func coordinatedWrite(_ manifest: ReaderProgressManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(manifest)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write-temp-then-replace so a crash mid-write never leaves a torn
        // manifest behind: the previous version stays intact instead.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".manifest-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var replacementError: (any Error)?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinated in
            do {
                if fileManager.fileExists(atPath: coordinated.path) {
                    _ = try fileManager.replaceItemAt(coordinated, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: coordinated)
                }
            } catch {
                replacementError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let replacementError { throw replacementError }
    }

    /// Starts and awaits an iCloud placeholder download. Throws when the file
    /// cannot materialize — the callers decide whether that means "use local"
    /// (load) or "retry later" (push).
    private static func ensureDownloaded(at url: URL) async throws {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        // Local test/override files and already materialized files do not
        // need a download request.
        guard values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            let current = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
            ])
            if current.ubiquitousItemDownloadingStatus == .current { return }
        }
        throw ReaderProgressICloudError.downloadTimedOut
    }

    /// Strip anything that isn't `[A-Za-z0-9._-]` so profile IDs are safe as
    /// a single path component. Profile IDs are already filesystem anchors,
    /// so this is belt-and-braces against a separator smuggling in a path
    /// traversal.
    private static func sanitized(_ profileID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let out = String(profileID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return out.isEmpty ? "default" : out
    }
}
