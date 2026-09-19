import AmgiAppCore
import AnkiBackend
import AnkiKit
import Foundation
import Observation

/// Launch-time collection open state. The app used to `try!` its
/// `openCollection` — which became a guaranteed launch crash the moment
/// MCP helper sessions could hold the collection while the app is closed
/// (rslib's exclusive lock). Now a failed open degrades to a busy screen
/// with a background retry. Helpers release direct ownership at the end of
/// every tool request and refuse new direct ownership once the app process
/// appears, so this retry normally covers only an in-flight request.
@MainActor
@Observable
final class CollectionLaunchState {
    static let shared = CollectionLaunchState()

    /// Non-nil while the collection could not be opened — the root scene
    /// shows the busy screen instead of the app content.
    private(set) var openError: String?

    private var backend: AnkiBackend?
    private var profileID: String = "default"
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = 0
    private var openAttemptInFlight = false

    func configure(backend: AnkiBackend?, profileID: String, error: String?) {
        self.backend = backend
        self.profileID = profileID
        self.openError = error
        if error != nil {
            startRetryLoop()
        }
    }

    /// Manual retry from the busy screen. Cancel the sleeping loop and start
    /// a fresh one whose first attempt is immediate.
    func retryNow() {
        // An FFI open cannot be cancelled. Let that attempt finish rather
        // than overlap two opens on the same backend; the normal result will
        // arrive sooner than a replacement could safely start.
        guard !openAttemptInFlight else { return }
        retryTask?.cancel()
        retryTask = nil
        startRetryLoop()
    }

    private func startRetryLoop() {
        guard retryTask == nil, backend != nil else { return }
        retryGeneration += 1
        let generation = retryGeneration
        retryTask = Task { [weak self] in
            await self?.retryUntilOpen(generation: generation)
        }
    }

    private func retryUntilOpen(generation: Int) async {
        defer {
            // A cancelled attempt can overlap the replacement briefly while
            // detached FFI returns. Never let it clear the newer task handle.
            if retryGeneration == generation {
                retryTask = nil
            }
        }
        var delay = Duration.zero
        while openError != nil, let backend {
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return  // cancelled or superseded by retryNow()
                }
            }
            guard openError != nil else { return }
            // Resolve MainActor-isolated paths BEFORE leaving the actor;
            // only the blocking FFI runs detached.
            let ankiDir = AccountStore.profileDirectory(for: profileID)
            let collectionPath = ankiDir.appendingPathComponent("collection.anki2").path
            let mediaPath = ankiDir.appendingPathComponent("media").path
            let mediaDbPath = ankiDir.appendingPathComponent("media.db").path
            openAttemptInFlight = true
            let result = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try FileManager.default.createDirectory(
                        atPath: mediaPath, withIntermediateDirectories: true)
                    try backend.openCollection(
                        collectionPath: collectionPath,
                        mediaFolderPath: mediaPath,
                        mediaDbPath: mediaDbPath
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            openAttemptInFlight = false
            // Loop condition re-checks: a nil result clears the error.
            openError = result
            // Fast takeover for the normal MCP hand-off, with a modest cap
            // so a genuinely damaged/busy collection does not hot-loop.
            delay = delay == .zero ? .milliseconds(250) : min(delay * 2, .seconds(1))
        }
    }
}
