import AmgiAppCore
import AnkiBackend
import AnkiKit
import Foundation
import Observation

/// Launch-time collection open state. The app used to `try!` its
/// `openCollection` — which became a guaranteed launch crash the moment
/// MCP helper sessions could hold the collection while the app is closed
/// (rslib's exclusive lock). Now a failed open degrades to a busy screen
/// with a background retry: the helpers probe `mcp.sock` per call, so the
/// moment the app finishes opening, their traffic switches to bridged
/// mode and everything converges.
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

    func configure(backend: AnkiBackend?, profileID: String, error: String?) {
        self.backend = backend
        self.profileID = profileID
        self.openError = error
        if error != nil {
            startRetryLoop()
        }
    }

    /// Manual retry from the busy screen (the background loop already
    /// retries every 2 s — this just doesn't wait for the next tick).
    func retryNow() {
        guard retryTask == nil else { return }
        startRetryLoop()
    }

    private func startRetryLoop() {
        guard retryTask == nil, backend != nil else { return }
        retryTask = Task { [weak self] in
            await self?.retryUntilOpen()
        }
    }

    private func retryUntilOpen() async {
        while openError != nil, let backend {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return  // cancelled (app quitting)
            }
            guard openError != nil else { return }
            // Resolve MainActor-isolated paths BEFORE leaving the actor;
            // only the blocking FFI runs detached.
            let ankiDir = AccountStore.profileDirectory(for: profileID)
            let collectionPath = ankiDir.appendingPathComponent("collection.anki2").path
            let mediaPath = ankiDir.appendingPathComponent("media").path
            let mediaDbPath = ankiDir.appendingPathComponent("media.db").path
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
            // Loop condition re-checks: a nil result clears the error.
            openError = result
        }
        retryTask = nil
    }
}
