public import Foundation
public import AmgiAppCore

/// Stable identity for the one review session allowed to drive the shared
/// scheduler at a time. `profileID` is generation-qualified and
/// `selectionID` fences a single activation of that profile, so switching away
/// and back can never revive a lease held by the old activation.
public struct ReviewSessionIdentity: Hashable, Sendable {
    public let sessionID: UUID
    public let profileID: String
    public let profileSelectionID: UUID

    public init(sessionID: UUID, profile: ProfileContext) {
        self.sessionID = sessionID
        self.profileID = profile.id
        self.profileSelectionID = profile.selectionID
    }
}

/// Capability token for the process-wide scheduler / current-deck / undo
/// lease. Only the exact token returned by `acquireSession` may begin engine
/// work. It is intentionally a value: a copied or stale token cannot take
/// ownership from a newer session.
public struct ReviewSessionLease: Hashable, Sendable {
    public let identity: ReviewSessionIdentity
    public let profile: ProfileContext

    fileprivate init(identity: ReviewSessionIdentity, profile: ProfileContext) {
        self.identity = identity
        self.profile = profile
    }
}

public enum ReviewSessionLeaseError: LocalizedError, Equatable, Sendable {
    case draining
    case alreadyActive(ReviewSessionIdentity)

    public var errorDescription: String? {
        switch self {
        case .draining:
            return L10n.text("The collection is switching profiles. Try the review again when switching finishes.")
        case .alreadyActive:
            return L10n.text("Another review window is already using this collection. Finish or close it before starting another review.")
        }
    }
}

/// Process-wide coordinator for review work that mutates the shared engine.
///
/// The scheduler exposes one mutable current deck and one undo/redo stack per
/// open collection. Merely counting mutations is therefore insufficient: two
/// otherwise valid reviews can interleave `SetCurrentDeck`, `AnswerCard`, and
/// `Undo` operations and make each session restore the wrong state. This
/// coordinator grants one profile-scoped lease and admits one mutation at a
/// time. Profile draining revokes that lease only after all in-flight work has
/// stopped, allowing the next profile activation to acquire a fresh lease
/// without any Root changes.
@MainActor
public final class ReviewSessionCoordinator {
    public static let shared = ReviewSessionCoordinator()

    private var activeLease: ReviewSessionLease?
    private var activeMutation: Bool = false
    /// Reads admitted under the active lease. Only these hold the lease open.
    private var leaseReads = 0
    /// Lease-less reads (indexer, App Intents). They block a profile drain,
    /// never a lease release: the indexer reads near-continuously, and
    /// letting it veto release stranded closed reviews' leases.
    private var externalReads = 0
    /// A release that arrived while the lease's own work was in flight. It
    /// completes when that work ends, so no caller has to retry.
    private var pendingRelease: ReviewSessionLease?
    private var isDraining = false

    /// Public for deterministic isolated tests. Production callers use
    /// `shared` so all review windows coordinate through one process-wide lock.
    public init() {}

    public var activeSession: ReviewSessionIdentity? {
        activeLease?.identity
    }

    public var hasActiveSession: Bool {
        activeLease != nil
    }

    /// Acquires the scheduler lease. Reacquisition by the same session/profile
    /// is idempotent, which keeps a failed start retryable.
    public func acquireSession(
        sessionID: UUID,
        profile: ProfileContext
    ) throws -> ReviewSessionLease {
        guard !isDraining else { throw ReviewSessionLeaseError.draining }
        let identity = ReviewSessionIdentity(sessionID: sessionID, profile: profile)
        if let activeLease {
            guard activeLease.identity == identity else {
                throw ReviewSessionLeaseError.alreadyActive(activeLease.identity)
            }
            pendingRelease = nil
            return activeLease
        }
        let lease = ReviewSessionLease(identity: identity, profile: profile)
        activeLease = lease
        return lease
    }

    /// Releases a lease. If a mutation or one of the lease's own reads is in
    /// flight, the release is deferred to when that work ends and this
    /// returns `false`. A stale token can never release a newer session's
    /// lease.
    @discardableResult
    public func releaseSession(_ lease: ReviewSessionLease) -> Bool {
        guard activeLease == lease else { return false }
        guard !activeMutation, leaseReads == 0 else {
            pendingRelease = lease
            return false
        }
        activeLease = nil
        pendingRelease = nil
        return true
    }

    private func completePendingRelease() {
        guard let pendingRelease, !activeMutation, leaseReads == 0 else { return }
        self.pendingRelease = nil
        if activeLease == pendingRelease { activeLease = nil }
    }

    /// Admits a profile-scoped read alongside scheduler mutations. Backend
    /// RPCs serialize individually; this token keeps profile draining from
    /// closing the collection while the read is queued or in flight.
    public func beginRead(for lease: ReviewSessionLease) -> Bool {
        guard !isDraining, activeLease == lease else { return false }
        leaseReads += 1
        return true
    }

    /// App-agent/indexer reads are drained before the collection closes too.
    public func beginExternalRead() -> Bool {
        guard !isDraining else { return false }
        externalReads += 1
        return true
    }

    public func endRead(for lease: ReviewSessionLease) {
        precondition(leaseReads > 0, "Review session read ended without a matching begin")
        leaseReads -= 1
        completePendingRelease()
    }

    public func endExternalRead() {
        precondition(externalReads > 0, "External read ended without a matching begin")
        externalReads -= 1
    }

    /// Starts one lease-owned engine transaction.
    public func beginMutation(for lease: ReviewSessionLease) -> Bool {
        guard !isDraining, !activeMutation, activeLease == lease else { return false }
        activeMutation = true
        return true
    }

    /// Legacy collection-lifecycle entry point used by Root and temporary-deck
    /// cleanup. It is serialized with lease-owned work but does not grant an
    /// engine lease of its own.
    public func beginMutation() -> Bool {
        guard !isDraining, !activeMutation else { return false }
        activeMutation = true
        return true
    }

    public func endMutation() {
        precondition(activeMutation, "Review session mutation ended without a matching begin")
        activeMutation = false
        completePendingRelease()
    }

    /// Prevents new work, waits for the current serialized transaction, then
    /// revokes the old profile activation's lease. The caller must pair this
    /// with `endDrain()` after closing/reopening the collection.
    public func drain() async {
        isDraining = true
        while activeMutation || leaseReads > 0 || externalReads > 0 {
            await Task.yield()
        }
        activeLease = nil
        pendingRelease = nil
    }

    public func endDrain() {
        isDraining = false
    }
}

/// Source-compatible name retained for the existing profile-switch drain in
/// Root. `ReviewSessionActivity.shared` and `ReviewSessionCoordinator.shared`
/// intentionally refer to the same coordinator instance.
public typealias ReviewSessionActivity = ReviewSessionCoordinator
