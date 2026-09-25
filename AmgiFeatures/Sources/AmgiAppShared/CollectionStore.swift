import AmgiAppCore
import AnkiClients
public import AnkiKit
public import Dependencies
import Foundation
public import Observation

public enum CollectionChangeOrigin: Sendable, Equatable {
    case localUser
    case remoteSync
    /// ijuka-mcp helper wrote to the shared collection from outside the
    /// app process. Refreshes UI and rides the automatic sync like a
    /// local user change, since the edit is ours to propagate.
    case helperMutation
    case refresh
}

/// Single refresh authority for Collection reads — deck tree (+ its due
/// counts) in v1. Screens key `.task(id: store.generation)` so an
/// Invalidation re-runs their load; mutations hand their
/// `CollectionChanges` to `apply(_:)`; sync/import/review-end call
/// `invalidateAll()`.
@Observable
@MainActor
public final class CollectionStore {
    /// Bumped by every Invalidation that affects the deck tree.
    public private(set) var generation = 0

    /// Nonisolated so `CollectionStoreKey`'s lazy statics can be initialized
    /// from any thread. Only stored-property defaults run here.
    public nonisolated init() {}

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient

    /// Called after a collection mutation is confirmed. The sink is injected
    /// by the app composition root so this module does not need to depend on
    /// SyncFeature or on any other feature that reacts to collection changes.
    @ObservationIgnored public var onCollectionChange: ((CollectionChangeOrigin) -> Void)?

    @ObservationIgnored private var cachedTree: [DeckTreeNode]?
    @ObservationIgnored private var cachedGeneration = -1
    @ObservationIgnored private var inFlight: Task<[DeckTreeNode], any Error>?
    @ObservationIgnored private var inFlightGeneration = -1
    @ObservationIgnored private var profileID: String?

    /// Discards every value that belongs to the previously opened collection.
    /// Call this before changing profiles; `tree()` also performs the check so
    /// a missed lifecycle hook can never return another profile's cached IDs.
    public func resetForProfileSwitch(to profileID: String) {
        guard self.profileID != profileID else { return }
        self.profileID = profileID
        generation &+= 1
        cachedTree = nil
        cachedGeneration = -1
        inFlight?.cancel()
        inFlight = nil
        inFlightGeneration = -1
    }

    private func alignWithSelectedProfile() {
        let selected = AccountStore.shared.selectedID
        if profileID != selected {
            resetForProfileSwitch(to: selected)
        }
    }

    /// Read-through deck tree. Concurrent callers share one fetch; a
    /// generation bump makes both the cache and any in-flight fetch stale.
    public func tree() async throws -> [DeckTreeNode] {
        alignWithSelectedProfile()
        if let cachedTree, cachedGeneration == generation {
            return cachedTree
        }
        if let inFlight, inFlightGeneration == generation {
            return try await inFlight.value
        }
        let fetchGeneration = generation
        let client = deckClient
        let task = Task { try await client.fetchTree() }
        inFlight = task
        inFlightGeneration = fetchGeneration
        defer {
            if inFlightGeneration == fetchGeneration { inFlight = nil }
        }
        let tree = try await task.value
        if fetchGeneration == generation {
            cachedTree = tree
            cachedGeneration = fetchGeneration
        }
        return tree
    }

    /// Fetches the deck tree without consulting or updating the UI cache.
    /// Snapshot writers use this after a mutation so a newly opened profile
    /// or an invalidation racing the write cannot publish stale due counts.
    public func freshTree() async throws -> [DeckTreeNode] {
        alignWithSelectedProfile()
        return try await deckClient.fetchTree()
    }

    public func apply(_ changes: CollectionChanges, origin: CollectionChangeOrigin = .localUser) {
        if changes.affectsDeckTree {
            generation += 1
        }
        notifyCollectionChange(origin)
    }

    public func invalidateAll(origin: CollectionChangeOrigin = .refresh) {
        generation += 1
        notifyCollectionChange(origin)
    }

    /// Records a confirmed mutation that does not invalidate the deck tree
    /// itself (for example, a review answer or a tag-only edit). These still
    /// need a sync and a widget refresh, even though the cached tree remains
    /// valid.
    public func markLocalMutation() {
        notifyCollectionChange(.localUser)
    }

    private func notifyCollectionChange(_ origin: CollectionChangeOrigin) {
        guard origin != .refresh else { return }
        onCollectionChange?(origin)
    }
}

private enum CollectionStoreKey: DependencyKey {
    // `static let` is initialized lazily by whichever thread touches it
    // first, which is not guaranteed to be the main thread. The old
    // `MainActor.assumeIsolated { ... }` would therefore trip "Incorrect
    // actor executor assumption" and abort the process if first resolved
    // from any Task.detached (there are 15+) or a background test.
    // CollectionStore has no explicit init, so a nonisolated one is safe and
    // removes the assumption entirely.
    static let liveValue = CollectionStore()
    static let testValue = CollectionStore()
}

extension DependencyValues {
    public var collectionStore: CollectionStore {
        get { self[CollectionStoreKey.self] }
        set { self[CollectionStoreKey.self] = newValue }
    }
}
