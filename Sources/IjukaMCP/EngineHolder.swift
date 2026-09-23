import Foundation
import AnkiBackend
import AnkiKit

/// Lazily-resolved engine access for tool handlers.
///
/// Resolution order per call:
///   1. **Bridged mode** — Ijuka.app is running and serving its IPC
///      bridge; RPCs are forwarded to the app's live engine. This is the
///      simultaneous-operation path: agents work while the app is open,
///      changes flow through the app's own UI/sync machinery.
///   2. **Direct mode** — no bridge (app quit), so we open the collection
///      for the duration of the active tool call. Idle MCP servers never
///      retain the collection lock. If the app starts before its bridge is
///      ready, direct access is refused so the app always wins ownership.
final class EngineHolder: Sendable {
    struct State {
        var proxyActive = false
        var localBackend: AnkiBackend?
        var lastError: String?
        var activeToolCalls = 0
    }

    private let paths: CollectionPaths
    private let stateBox = StateBox()

    init(paths: CollectionPaths) {
        self.paths = paths
    }

    /// Brackets one MCP tool request. Direct backends are shared by
    /// concurrent requests, then closed as soon as the final request ends.
    /// This is the key ownership rule: an idle MCP process owns nothing.
    func beginToolCall() {
        stateBox.withLock { $0.activeToolCalls += 1 }
    }

    func endToolCall() {
        stateBox.withLock { state in
            precondition(state.activeToolCalls > 0, "unbalanced MCP engine lease")
            state.activeToolCalls -= 1
            guard state.activeToolCalls == 0, let backend = state.localBackend else { return }
            do {
                try backend.closeCollection()
                state.lastError = nil
            } catch {
                // Dropping the backend still closes the Rust backend handle;
                // retain the diagnostic for collection_status.
                state.lastError = "direct collection close failed: \(error.localizedDescription)"
            }
            state.localBackend = nil
        }
    }

    /// Human-readable description for the collection_status tool.
    var modeDescription: String {
        stateBox.withLock { state in
            if state.proxyActive { return "bridged — calls run inside the running Ijuka.app" }
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
            let probe = ProxyCaller.probe(
                socketPath: MCPBridge.socketPath(),
                profileID: paths.profileID
            )
            if case .live(let session) = probe {
                state.proxyActive = true
                state.localBackend = nil
                state.lastError = nil
                return EngineCaller(kind: .bridged(session: session))
            }
            if case .unavailable(let message) = probe {
                state.proxyActive = false
                state.lastError = message
                throw ToolError.blocked(message)
            }
            state.proxyActive = false

            // The GUI is the collection authority. There is a small launch
            // window between NSWorkspace seeing it and mcp.sock accepting;
            // never use that window to steal the collection from the app.
            if AppRunningCheck.isIjukaRunning {
                state.lastError = "Ijuka.app is starting; its MCP bridge is not ready yet"
                throw ToolError.blocked(
                    "Ijuka.app is starting and taking ownership of the collection. " +
                    "Retry this tool call in a moment; it will run through the app bridge."
                )
            }

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
                monitorForAppLaunch(whileOwning: backend)
                return EngineCaller(kind: .local(backend))
            } catch {
                state.lastError = error.localizedDescription
                throw ToolError.blocked(
                    "collection '\(paths.profileID)' is not accessible right now — " +
                    "another process may be finishing a request. Retry in a moment. " +
                    "(\(error.localizedDescription))"
                )
            }
        }
    }

    /// Direct ownership is only a fallback while the GUI is absent. If Ijuka
    /// starts during a long engine RPC, request Anki's cooperative abort so
    /// the request lease can unwind and the app can acquire the collection.
    private func monitorForAppLaunch(whileOwning backend: AnkiBackend) {
        Thread.detachNewThread { [weak self, backend] in
            while let self {
                let stillOwned = self.stateBox.withLock { $0.localBackend === backend }
                guard stillOwned else { return }
                if AppRunningCheck.isIjukaRunning {
                    backend.requestAbort()
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
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
