public import AppIntents
public import AmgiAppCore
import CoreSpotlight
import Foundation
import Observation

/// Maintains the small, privacy-conscious Spotlight surface: deck names only.
/// Note bodies and answers are intentionally not indexed. Identifiers are
/// profile-scoped and stale entries are removed whenever a deck disappears.
public actor SystemSpotlightIndexer {
    public static let shared = SystemSpotlightIndexer()

    // CoreSpotlight's App Intents indexing bridge is thread-safe and all use
    // is serialized by this actor, but the Objective-C class has not yet
    // adopted Sendable in the SDK.
    nonisolated(unsafe) private let index: CSSearchableIndex
    private let defaults: UserDefaults
    private var pendingRefresh: Task<Void, Never>?
    private static let indexedProfilesKey = "automation.spotlight.indexedProfiles"

    public static var defaultIndexName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.bagumamartin.ijuka").spotlight.decks.v1"
    }

    public init(
        indexName: String? = nil,
        defaults: UserDefaults = AppGroup.defaults
    ) {
        let resolvedName = indexName ?? Self.defaultIndexName
        self.index = CSSearchableIndex(name: resolvedName)
        self.defaults = defaults
    }

    /// Coalesces bursts of collection activity into one index pass.
    public func scheduleDeckRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            try? await self?.refreshDecks()
        }
    }

    public func refreshDecks() async throws {
        pendingRefresh?.cancel()
        pendingRefresh = nil

        let context = await AccountStore.shared.selectedContext
        let profileID = context.id
        let key = indexedIDsKey(profileID)
        let knownProfiles = Set(
            defaults.stringArray(forKey: Self.indexedProfilesKey) ?? []
        ).union([profileID])

        if !AutomationPreferences.spotlightDeckNames {
            for knownProfile in knownProfiles {
                try await removeStoredEntries(for: knownProfile)
            }
            defaults.removeObject(forKey: Self.indexedProfilesKey)
            return
        }

        // Only the active collection can be queried safely. Remove entries
        // belonging to profiles that are no longer active; switching back will
        // re-index that profile from a fresh, profile-scoped deck snapshot.
        for knownProfile in knownProfiles where knownProfile != profileID {
            try await removeStoredEntries(for: knownProfile)
        }

        let entities = try await DeckEntity.currentEntities()
        guard context.isCurrent(await AccountStore.shared.selectedContext) else { return }
        let currentIDs = Set(entities.map(\.id))
        let staleIDs = storedIDs(forKey: key).subtracting(currentIDs)
        if !staleIDs.isEmpty {
            try await index.deleteAppEntities(identifiedBy: Array(staleIDs), ofType: DeckEntity.self)
        }
        if !entities.isEmpty {
            try await index.indexAppEntities(entities)
        }
        guard context.isCurrent(await AccountStore.shared.selectedContext) else {
            // The system may have switched profiles while donation awaited
            // the index. Remove this batch explicitly because its IDs were
            // not yet recorded in the per-profile cleanup key.
            if !currentIDs.isEmpty {
                try? await index.deleteAppEntities(
                    identifiedBy: Array(currentIDs),
                    ofType: DeckEntity.self
                )
            }
            try? await removeStoredEntries(for: profileID)
            return
        }
        defaults.set(Array(currentIDs).sorted(), forKey: key)
        defaults.set([profileID], forKey: Self.indexedProfilesKey)
    }

    private func removeStoredEntries(for profileID: String) async throws {
        let key = indexedIDsKey(profileID)
        let previous = storedIDs(forKey: key)
        if !previous.isEmpty {
            try await index.deleteAppEntities(identifiedBy: Array(previous), ofType: DeckEntity.self)
        }
        defaults.removeObject(forKey: key)
    }

    private func storedIDs(forKey key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func indexedIDsKey(_ profileID: String) -> String {
        "automation.spotlight.indexedDeckIDs.\(profileID)"
    }
}
