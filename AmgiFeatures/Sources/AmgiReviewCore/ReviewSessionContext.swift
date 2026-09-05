package import AnkiKit
package import Foundation

/// Process-wide holder of the live review-session snapshot, read by
/// `MCPBridgeServer` when the helper asks for session state over
/// `mcp.sock`. Lock-based (not actor-isolated) because the bridge's
/// accept loop runs on a dedicated Foundation thread.
///
/// The watch app also builds `ReviewSession`s, but on the watch this
/// type simply publishes into the watch's own memory — the Mac helper
/// reads the Mac process, so there is no cross-device concern.
package final class ReviewSessionContext: @unchecked Sendable {
    package static let shared = ReviewSessionContext()

    private let lock = NSLock()
    private var snapshot: ReviewSessionSnapshot?

    package func publish(_ snapshot: ReviewSessionSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    package func clear() {
        lock.lock()
        self.snapshot = nil
        lock.unlock()
    }

    /// Encoded JSON for the bridge reply, or nil when no session is live.
    package func encodedSnapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot else { return nil }
        return try? JSONEncoder().encode(snapshot)
    }
}
