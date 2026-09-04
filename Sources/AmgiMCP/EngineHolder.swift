import Foundation
import AnkiBackend
import AnkiKit

/// Lazily-resolved engine access for tool handlers.
///
/// Resolution order per call:
///   1. **Bridged mode** — Amgi.app is running and serving its IPC
///      bridge; RPCs are forwarded to the app's live engine. This is the
///      simultaneous-operation path: agents work while the app is open,
///      changes flow through the app's own UI/sync machinery.
///   2. **Direct mode** — no bridge (app quit), so we open the
///      collection here. If the app grabbed the lock between checks,
///      the open fails with a clear "quit Amgi" message and the next
///      call retries.
final class EngineHolder: Sendable {
    struct State {
        var proxyActive = false
        var localBackend: AnkiBackend?
        var lastError: String?
    }

    private let paths: CollectionPaths
    private let stateBox = StateBox()

    init(paths: CollectionPaths) {
        self.paths = paths
    }

    /// Human-readable description for the collection_status tool.
    var modeDescription: String {
        stateBox.withLock { state in
            if state.proxyActive { return "bridged — calls run inside the running Amgi.app" }
            if state.localBackend != nil { return "direct — this process owns the collection" }
            if let lastError = state.lastError { return "closed — \(lastError)" }
            return "closed (no call has opened it yet)"
        }
    }

    var lastErrorDescription: String? {
        stateBox.withLock { $0.lastError }
    }

    /// The active caller, establishing bridged/direct as needed.
    func caller() throws -> EngineCaller {
        try stateBox.withLock { state -> EngineCaller in
            // Probe EVERY call: the bridge can disappear mid-session
            // (force-quit) and reappear later (relaunch). The probe is
            // sub-millisecond against a live app and fails fast against
            // a dead/stale socket (which gets swept as a bonus).
            if ProxyCaller.ping(socketPath: MCPBridge.socketPath()) {
                state.proxyActive = true
                state.localBackend = nil
                state.lastError = nil
                return EngineCaller(kind: .bridged(socketPath: MCPBridge.socketPath()))
            }
            state.proxyActive = false

            if let existing = state.localBackend {
                return EngineCaller(kind: .local(existing))
            }
            do {
                let backend = try AnkiBackend(preferredLangs: ["en"])
                try FileManager.default.createDirectory(
                    atPath: paths.mediaFolderPath, withIntermediateDirectories: true
                )
                try backend.openCollection(
                    collectionPath: paths.collectionPath,
                    mediaFolderPath: paths.mediaFolderPath,
                    mediaDbPath: paths.mediaDbPath
                )
                state.localBackend = backend
                state.lastError = nil
                return EngineCaller(kind: .local(backend))
            } catch {
                state.lastError = error.localizedDescription
                throw ToolError.blocked(
                    "collection '\(paths.profileID)' is not accessible right now — " +
                    "Amgi.app may be running and holding it. Quit the app and retry. (\(error.localizedDescription))"
                )
            }
        }
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()

        func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }
    }
}
