public import Foundation
import AnkiKit
import Observation

/// One Anki profile. Each profile owns an isolated collection
/// (`<appSupport>/AnkiCollection/<id>/collection.anki2`) and per-profile
/// sync prefs (already scoped via `SyncPreferences.currentProfileID()`).
/// The slug remains the filesystem anchor; `AccountStore.scopeID(for:)`
/// adds a generation for system-facing persisted records.
public struct AmgiAccount: Identifiable, Hashable, Codable, Sendable {
    /// Filesystem-safe slug used for the per-profile directory and as
    /// the value of `amgi.selectedUser` (the existing scoping anchor).
    public let id: String
    /// User-visible display name. Free text; the slug is derived once
    /// at create-time and never renamed (would orphan the directory).
    public var displayName: String
    /// When the user first created this profile. Used for sort + the
    /// "since X" line in the picker.
    public let createdAt: Date

    public static let defaultID = "default"
    public static let defaultName = "Default"

    public static func newDefault() -> AmgiAccount {
        AmgiAccount(id: defaultID, displayName: defaultName, createdAt: .now)
    }
}

/// Persistent profile registry. The list of accounts and the current
/// selection both live in `UserDefaults`; per-profile state (collection,
/// sync prefs, keychain sync identity) lives elsewhere and is keyed off
/// `AmgiAccount.id` via the `amgi.selectedUser` anchor.
///
/// Switching is in-app: `switchProfile(to:)` (AmgiAppApp.swift) swaps the
/// open collection on the shared backend, calls `select(_:)` to flip the
/// scoping anchor, and the root view re-ids on `selectionID` so the whole
/// UI rebuilds against the new collection activation.
@MainActor
@Observable
public final class AccountStore {
    public static let shared = AccountStore()

    private static let accountsKey = "amgi.accounts"
    private static let selectedKey = ProfileScope.anchorKey
    private static let scopeGenerationsKey = "amgi.profile.scopeGenerations"

    public private(set) var accounts: [AmgiAccount]
    public private(set) var selectedID: String

    /// Changes whenever the active collection changes. This is deliberately
    /// runtime-only: persisted system entities are scoped by the stable
    /// profile ID, while in-flight intents and routes use this value to detect
    /// a profile switch before reading or writing the wrong collection.
    public private(set) var selectionID = UUID()

    /// Monotonic generation per filesystem slug. The slug remains the
    /// collection/keychain anchor, while system-facing scope IDs include this
    /// generation so deleting and recreating a profile cannot revive old
    /// Shortcuts, Spotlight records, or navigation requests.
    private var scopeGenerations: [String: Int]

    /// Set when a profile switch could not reopen *any* collection, leaving
    /// the app with nothing open. Surfaced by the root view so the state is
    /// visible rather than presenting as a mysteriously empty app.
    public var switchFailure: String?

    /// Binding projection for the failure alert. SwiftUI wants a `Bool`
    /// binding and the state is an optional message; a get/set closure
    /// `Binding` at the call site allocates on every body evaluation and
    /// defeats comparison, so the projection lives here instead.
    ///
    /// Writing `true` is a no-op: only a failed switch produces a message.
    public var hasSwitchFailure: Bool {
        get { switchFailure != nil }
        set { if !newValue { switchFailure = nil } }
    }

    private init() {
        let defaults = UserDefaults.standard
        scopeGenerations = defaults.dictionary(forKey: Self.scopeGenerationsKey) as? [String: Int] ?? [:]
        if let data = defaults.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([AmgiAccount].self, from: data),
           !decoded.isEmpty {
            self.accounts = decoded
        } else {
            // First-run: seed with the legacy single-profile setup.
            self.accounts = [.newDefault()]
        }
        self.selectedID = defaults.string(forKey: Self.selectedKey) ?? AmgiAccount.defaultID

        // Backfill: ensure the selected ID exists in the list.
        if !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = accounts.first?.id ?? AmgiAccount.defaultID
        }
        persistAccounts()
        persistSelection()
    }

    public var current: AmgiAccount {
        accounts.first(where: { $0.id == selectedID }) ?? accounts[0]
    }

    /// Opaque, stable identity used by system-facing persisted records. The
    /// first generation keeps the historical slug form for migration safety;
    /// later generations use `~`, which cannot occur in a profile slug and
    /// therefore cannot collide with a separately named profile.
    public func scopeID(for account: AmgiAccount) -> String {
        let generation = scopeGenerations[account.id, default: 0]
        return generation == 0 ? account.id : "\(account.id)~g\(generation)"
    }

    /// Adds a new profile. Returns the canonical id used (slug derived
    /// from displayName). Throws if the slug collides with an existing
    /// profile or is empty after sanitization.
    @discardableResult
    public func add(displayName: String) throws -> AmgiAccount {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AccountStoreError.emptyName
        }
        let id = Self.slug(from: trimmed)
        guard !id.isEmpty else { throw AccountStoreError.emptyName }
        if accounts.contains(where: { $0.id == id }) {
            throw AccountStoreError.duplicateName
        }
        let account = AmgiAccount(id: id, displayName: trimmed, createdAt: .now)
        accounts.append(account)
        persistAccounts()
        return account
    }

    /// Removes a profile and (if requested) its on-disk collection.
    /// Refuses to delete the active profile or the last remaining one.
    public func remove(_ account: AmgiAccount, deleteFiles: Bool) throws {
        guard accounts.count > 1 else { throw AccountStoreError.cannotDeleteLast }
        guard account.id != selectedID else { throw AccountStoreError.cannotDeleteActive }
        scopeGenerations[account.id, default: 0] += 1
        persistScopeGenerations()
        accounts.removeAll { $0.id == account.id }
        persistAccounts()
        if deleteFiles {
            let dir = Self.profileDirectory(for: account.id)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Marks `account` as the active profile and persists the selection —
    /// this flips the scoping anchor for sync prefs and keychain identity.
    /// Collection close/reopen is the caller's job (`switchProfile(to:)`).
    public func select(_ account: AmgiAccount) {
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        if selectedID != account.id {
            selectionID = UUID()
        }
        selectedID = account.id
        persistSelection()
    }

    // MARK: - Filesystem helpers

    /// Parent of every profile directory (canonical via `CollectionLayout`
    /// so the app, watch, and ijuka-mcp helper agree).
    public static var collectionRoot: URL {
        CollectionLayout.rootDirectory()
    }

    /// Per-profile collection directory. Files inside follow Anki's
    /// layout: `collection.anki2`, `media/`, `media.db`.
    public static func profileDirectory(for id: String) -> URL {
        CollectionLayout.profileDirectory(for: id)
    }

    /// One-time migration on first multi-profile launch: if there's a
    /// legacy `AnkiCollection/collection.anki2` outside any profile
    /// dir, move it into the default profile's directory.
    public static func migrateLegacyCollectionIfNeeded() {
        let legacyRoot = collectionRoot
        let legacyCollection = legacyRoot.appendingPathComponent("collection.anki2")
        let target = profileDirectory(for: AmgiAccount.defaultID)
        let targetCollection = target.appendingPathComponent("collection.anki2")
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyCollection.path),
              !fm.fileExists(atPath: targetCollection.path) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["collection.anki2", "media", "media.db"] {
            let src = legacyRoot.appendingPathComponent(name)
            let dst = target.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
    }

    // MARK: - Persistence

    // MARK: - Slug

    /// Filesystem- and pref-key-safe slug. Lowercased, alphanumerics +
    /// `-_`, collapsed underscores, length-capped. The same rule as
    /// `SyncPreferences.currentProfileID()` so the scoping anchor lines
    /// up.
    static func slug(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let lower = name.lowercased()
        let mapped = lower.unicodeScalars.map { Character(allowed.contains($0) ? $0 : "_") }
        let collapsed = String(mapped)
            .components(separatedBy: "_")
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let trimmed = String(collapsed.prefix(40))
        return trimmed.isEmpty ? "" : trimmed
    }
}

enum AccountStoreError: LocalizedError {
    case emptyName
    case duplicateName
    case cannotDeleteLast
    case cannotDeleteActive

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Profile name can't be empty."
        case .duplicateName: return "A profile with that name already exists."
        case .cannotDeleteLast: return "You need at least one profile."
        case .cannotDeleteActive: return "Switch to another profile before deleting this one."
        }
    }
}

private extension AccountStore {
    func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    func persistSelection() {
        UserDefaults.standard.set(selectedID, forKey: Self.selectedKey)
        // The widget extension has a separate defaults domain, so mirror both
        // anchors for profile-safe snapshot reads.
        AppGroup.defaults.set(selectedID, forKey: Self.selectedKey)
        let scopeID = self.scopeID(for: current)
        UserDefaults.standard.set(scopeID, forKey: AppGroup.selectedProfileScopeKey)
        AppGroup.defaults.set(scopeID, forKey: AppGroup.selectedProfileScopeKey)
    }

    func persistScopeGenerations() {
        UserDefaults.standard.set(scopeGenerations, forKey: Self.scopeGenerationsKey)
    }
}
