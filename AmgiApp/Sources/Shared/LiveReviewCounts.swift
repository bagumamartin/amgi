import AnkiKit
import Dependencies
import Foundation
import Observation

/// One published snapshot of an active review session's queue counts.
///
/// `baseline` is the session scope's counts at session start and `live` the
/// current remaining counts. Consumers that render the whole collection
/// (the Study ring) derive collection-wide live counts by subtracting the
/// session baseline from a pre-session collection snapshot and adding `live`.
public struct LiveReviewSnapshot: Equatable, Sendable {
    /// Stable per-session identity so consumers can re-anchor their
    /// collection snapshot exactly once per session.
    public let sessionID: UUID
    public let baseline: DeckCounts
    public let live: DeckCounts

    public init(sessionID: UUID, baseline: DeckCounts, live: DeckCounts) {
        self.sessionID = sessionID
        self.baseline = baseline
        self.live = live
    }
}

/// Shared live pulse of the active review session's queue counts. The Study
/// landing ring consumes this to repaint its new/learning/review composition
/// as cards are answered — a lightweight channel that avoids a full deck-tree
/// refetch per answer. `ReviewSession` publishes after every answer; the ring
/// clears on review dismiss (when the collection reloads from the backend).
@Observable
@MainActor
public final class LiveReviewCounts {
    private(set) var snapshot: LiveReviewSnapshot?

    public func publish(sessionID: UUID, baseline: DeckCounts, live: DeckCounts) {
        snapshot = LiveReviewSnapshot(sessionID: sessionID, baseline: baseline, live: live)
    }

    public func clear() {
        snapshot = nil
    }
}

private enum LiveReviewCountsKey: DependencyKey {
    static let liveValue: LiveReviewCounts = MainActor.assumeIsolated { LiveReviewCounts() }
    static let testValue: LiveReviewCounts = MainActor.assumeIsolated { LiveReviewCounts() }
}

extension DependencyValues {
    public var liveReviewCounts: LiveReviewCounts {
        get { self[LiveReviewCountsKey.self] }
        set { self[LiveReviewCountsKey.self] = newValue }
    }
}