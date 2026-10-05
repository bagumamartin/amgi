public import Foundation

/// A snapshot of where the user is inside a book — which chapter and how
/// far down it. `progress` is a 0..1 fraction; `updatedAt` is the wall-clock
/// time the snapshot was last written, used by sync layers to pick a winner
/// when multiple sources disagree.
public struct ReaderSavedProgress: Codable, Equatable, Sendable {
    public var chapterID: Int64
    public var progress: Double
    public var updatedAt: Date
    /// Optional text location for reflowable EPUBs. Other reader types keep
    /// using their established fractional/page restoration paths.
    public var anchor: ReaderSourceAnchor?

    public init(
        chapterID: Int64,
        progress: Double,
        updatedAt: Date,
        anchor: ReaderSourceAnchor? = nil
    ) {
        self.chapterID = chapterID
        self.progress = progress
        self.updatedAt = updatedAt
        self.anchor = anchor
    }
}

/// Local, single-device persistence for per-book reading progress. Stores
/// each book's `ReaderSavedProgress` as a JSON-encoded value in a
/// `UserDefaults` instance under a sanitized key.
///
/// Deliberately scoped to local persistence only. Cross-device sync via
/// the iCloud Drive progress manifest belongs in a sync adapter outside
/// this package; keeping it out of `AmgiReader` is what lets this package
/// stay free of sync-backend dependencies.
// `UserDefaults` is thread-safe but not formally `Sendable`. The struct is
// otherwise value-only, so `@unchecked Sendable` is honest here.
public struct ReaderProgressStore: @unchecked Sendable {
    /// Unscoped namespace used before progress became profile-owned. Still
    /// read as a fallback so existing positions migrate on first read.
    public static let legacyKeyNamespace = "amgi.reader.progress"

    private let userDefaults: UserDefaults
    private let keyNamespace: String
    private let legacyKeyNamespace: String?

    public init(
        userDefaults: UserDefaults = .standard,
        keyNamespace: String = ReaderProgressStore.legacyKeyNamespace
    ) {
        self.init(
            userDefaults: userDefaults,
            keyNamespace: keyNamespace,
            legacyKeyNamespace: nil
        )
    }

    /// Scoped form. `legacyKeyNamespace` is consulted only when the scoped key
    /// is absent, and only for the default profile: another profile must never
    /// inherit a position the shared namespace happened to hold.
    init(
        userDefaults: UserDefaults,
        keyNamespace: String,
        legacyKeyNamespace: String?
    ) {
        self.userDefaults = userDefaults
        self.keyNamespace = keyNamespace
        self.legacyKeyNamespace = legacyKeyNamespace
    }

    /// Progress scoped to `profileID`. Progress is per-profile state, so the
    /// key namespace carries the profile rather than the value itself.
    public static func scoped(
        to profileID: String,
        userDefaults: UserDefaults = .standard
    ) -> ReaderProgressStore {
        let sanitized = Self.sanitize(profileID)
        return ReaderProgressStore(
            userDefaults: userDefaults,
            keyNamespace: "\(legacyKeyNamespace)__\(sanitized.isEmpty ? "default" : sanitized)",
            legacyKeyNamespace: sanitized == "default" || sanitized.isEmpty
                ? legacyKeyNamespace
                : nil
        )
    }

    /// Progress scoped to the profile selected in `UserDefaults.standard`.
    ///
    /// The `AmgiReader` package has no edge to `AnkiKit`, so — exactly like
    /// `AmgiReaderDictionary`'s local copy of the anchor — it reads the
    /// `amgi.selectedUser` key itself rather than importing `ProfileScope`.
    /// Keep the key in sync with `ProfileScope.anchorKey`.
    public static func forCurrentProfile(
        userDefaults: UserDefaults = .standard
    ) -> ReaderProgressStore {
        let selected = userDefaults.string(forKey: "amgi.selectedUser")
            ?? "default"
        return scoped(to: selected, userDefaults: userDefaults)
    }

    public func load(bookID: String) -> ReaderSavedProgress? {
        if let data = userDefaults.data(forKey: storageKey(for: bookID)),
           let progress = try? JSONDecoder().decode(ReaderSavedProgress.self, from: data) {
            return progress
        }
        // Migration read: adopt the pre-profiles value once, then write it back
        // under the scoped key so the fallback stops firing.
        if let legacyKeyNamespace,
           let data = userDefaults.data(forKey: "\(legacyKeyNamespace).\(Self.sanitize(bookID))"),
           let progress = try? JSONDecoder().decode(ReaderSavedProgress.self, from: data) {
            save(bookID: bookID, payload: progress)
            return progress
        }
        return nil
    }

    public func save(bookID: String, chapterID: Int64, progress: Double, now: Date = .now) {
        let payload = ReaderSavedProgress(
            chapterID: chapterID,
            // Clamp to [0,1] so callers can pass raw scroll fractions
            // without having to range-check.
            progress: min(max(progress, 0), 1),
            updatedAt: now,
            anchor: nil
        )
        save(bookID: bookID, payload: payload)
    }

    public func save(bookID: String, payload: ReaderSavedProgress) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: storageKey(for: bookID))
    }

    // MARK: - Deferred cloud-side pushes
    //
    // The local write always lands, but the mirror into the iCloud Drive
    // manifest is a background task that can be lost to a backgrounding or a
    // force-quit. Book ids whose push has not landed are recorded here so a
    // later launch can retry, instead of letting cross-device progress
    // silently diverge.

    public func markPendingPush(bookID: String) {
        var pending = Set(pendingPushBookIDs())
        pending.insert(bookID)
        userDefaults.set(Array(pending), forKey: pendingPushKey)
    }

    public func clearPendingPush(bookID: String) {
        var pending = Set(pendingPushBookIDs())
        guard pending.remove(bookID) != nil else { return }
        userDefaults.set(Array(pending), forKey: pendingPushKey)
    }

    public func pendingPushBookIDs() -> [String] {
        userDefaults.stringArray(forKey: pendingPushKey) ?? []
    }

    private var pendingPushKey: String { "\(keyNamespace).pendingPushes" }

    private func storageKey(for bookID: String) -> String {
        "\(keyNamespace).\(Self.sanitize(bookID))"
    }

    /// Strip anything that isn't `[A-Za-z0-9._-]` so `UserDefaults` keys
    /// stay portable across the Apple sandbox layers (and so future code
    /// can't be tripped up by separators inside a book ID).
    private static func sanitize(_ bookID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(bookID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
    }
}
