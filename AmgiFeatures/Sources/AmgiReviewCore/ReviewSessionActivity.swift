import Foundation

/// Serializes review-session engine activity with collection lifecycle
/// changes. Profile switching drains this barrier before closing the current
/// collection, so a detached scheduler call cannot land in a newly opened
/// profile's database.
@MainActor
public final class ReviewSessionActivity {
    public static let shared = ReviewSessionActivity()

    private var activeMutations = 0
    private var isDraining = false

    private init() {}

    /// Reserves the collection for a review mutation. Returns false while a
    /// profile switch is draining the open collection.
    public func beginMutation() -> Bool {
        guard !isDraining else { return false }
        activeMutations += 1
        return true
    }

    public func endMutation() {
        precondition(activeMutations > 0, "Review session mutation count underflow")
        activeMutations -= 1
    }

    /// Prevents new review work and waits for all in-flight work to finish.
    /// The caller must pair this with `endDrain()`.
    public func drain() async {
        isDraining = true
        while activeMutations > 0 {
            await Task.yield()
        }
    }

    public func endDrain() {
        isDraining = false
    }
}
