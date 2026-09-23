#if os(macOS)
import AmgiAppShared
import AmgiReviewCore
import AnkiBackend
import AnkiKit
import Dependencies
import Foundation
import SyncFeature

/// Unix-socket bridge that lets ijuka-mcp execute RPCs against THIS
/// process's live engine while the app is running. This is what makes
/// agents and Ijuka work simultaneously: rslib serializes collection
/// access, so instead of fighting it, whichever process owns the engine
/// serves the other. When the app quits, its socket vanishes and the
/// helper falls back to opening the collection directly.
///
/// Protocol: AnkiKit.MCPBridge framing. Each MCP tool owns one persistent
/// connection, so its engine calls share a route and avoid reconnect churn.
///
/// Threading: the blocking accept loop owns a dedicated Foundation thread;
/// accepted sessions use a bounded worker pool so one slow agent cannot
/// prevent the app from serving others.
/// The master switch in Settings → Agent is honored live: each new
/// connection re-reads mcp.json and is refused when disabled.
package enum MCPBridgeServer {
    /// Called once from App.init after prepareDependencies — on the main
    /// actor, where dependency resolution sees the opened backend.
    package static func start() {

        @Dependency(\.ankiBackend) var backend
        @Dependency(\.collectionStore) var store

        let core = Core(backend: backend, store: store)
        Thread.detachNewThread {
            core.run()
        }
    }

    private struct Core: @unchecked Sendable {
        let backend: AnkiBackend
        let store: CollectionStore

        func run() {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            let socketPath = MCPBridge.socketPath()
            try? FileManager.default.removeItem(atPath: socketPath)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                return
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
            }

            let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0, listen(fd, 4) == 0 else {
                return
            }
            _ = chmod(socketPath, S_IRUSR | S_IWUSR)

            let clientSlots = DispatchSemaphore(value: 16)
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                guard clientSlots.wait(timeout: .now()) == .success else {
                    close(client)
                    continue
                }
                Thread.detachNewThread { [self] in
                    self.serve(client: client)
                    close(client)
                    clientSlots.signal()
                }
            }
        }

        private func serve(client: Int32) {
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE,
                &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            )
            var timeout = timeval(tv_sec: 120, tv_usec: 0)
            _ = setsockopt(
                client, SOL_SOCKET, SO_RCVTIMEO,
                &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))
            )
            _ = setsockopt(
                client, SOL_SOCKET, SO_SNDTIMEO,
                &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))
            )

            // Kill switch honored live: refuse connections when disabled.
            let settings: MCPSettings
            do {
                settings = try MCPSettings.loadStrict(
                    from: CollectionLayout.rootDirectory()
                        .appendingPathComponent("mcp.json").path
                )
            } catch {
                reply(
                    client,
                    status: .unavailable,
                    payload: Data("MCP settings are malformed; access is disabled until Ijuka rewrites them.".utf8)
                )
                return
            }
            guard settings.enabled else {
                reply(client, status: .unavailable, payload: Data("The agent server is switched off in Ijuka settings.".utf8))
                return
            }

            var buffer = Data()
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while true {
                do {
                    if let parsed = try MCPBridge.decodeFrame(from: buffer), parsed.consumed > 0 {
                        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + parsed.consumed)
                        handleFrame(parsed.frame, client: client, settings: settings)
                        continue
                    }
                } catch {
                    reply(
                        client,
                        status: .unavailable,
                        payload: Data(error.localizedDescription.utf8)
                    )
                    return
                }
                let n = recv(client, &scratch, scratch.count, 0)
                if n <= 0 { return }  // EOF or error → done with this client
                buffer.append(contentsOf: scratch[0..<n])
                if buffer.count > MCPBridge.maximumPayloadBytes + 8_192 { return }
            }
        }

        private func handleFrame(
            _ frame: MCPBridge.Frame,
            client: Int32,
            settings: MCPSettings
        ) {
            let activeProfile = UserDefaults.standard.string(forKey: "amgi.selectedUser")
                ?? "default"
            guard frame.profileID == activeProfile else {
                reply(
                    client, status: .unavailable,
                    payload: Data(
                        "Profile mismatch: agent requested '\(frame.profileID)' but Ijuka has '\(activeProfile)' open.".utf8
                    )
                )
                return
            }

            // App-level sentinel service (ping + session state) never
            // touches the engine — answered from process state.
            if frame.service == MCPBridge.pingService {
                if frame.method == MCPBridge.snapshotMethod {
                    do {
                        let profileDirectory = CollectionLayout.profileDirectory(for: activeProfile)
                        let collectionPath = profileDirectory
                            .appendingPathComponent("collection.anki2").path
                        let snapshot = try backend.withExclusiveAccess {
                            try CollectionSnapshotter.snapshot(
                                collectionPath: collectionPath,
                                profileDirectory: profileDirectory
                            )
                        }
                        reply(client, status: .ok, payload: Data(snapshot.path.utf8))
                    } catch {
                        reply(
                            client, status: .engineError,
                            payload: Data(error.localizedDescription.utf8)
                        )
                    }
                } else if frame.method == MCPBridge.sessionStateMethod {
                    if let payload = ReviewSessionContext.shared.encodedSnapshot() {
                        reply(client, status: .ok, payload: payload)
                    } else {
                        reply(
                            client, status: .unavailable,
                            payload: Data("No active review session — open Ijuka and start reviewing.".utf8)
                        )
                    }
                } else {
                    // Ping or any future sentinel: bare ok.
                    reply(client, status: .ok, payload: Data())
                }
                return
            }

            guard let requiredTier = MCPCallPolicy.requiredTier(
                service: frame.service,
                method: frame.method
            ) else {
                reply(
                    client, status: .unavailable,
                    payload: Data("This raw engine operation is not exposed through Ijuka MCP.".utf8)
                )
                return
            }
            guard requiredTier <= settings.tier else {
                reply(
                    client, status: .unavailable,
                    payload: Data(
                        "This engine operation requires the \(requiredTier.rawValue) MCP tier; the current tier is \(settings.tier.rawValue).".utf8
                    )
                )
                return
            }
            if requiredTier > .readOnly && settings.blockWritesWhileAppRunning {
                reply(
                    client, status: .unavailable,
                    payload: Data("Agent writes are blocked while Ijuka is running.".utf8)
                )
                return
            }

            do {
                let response = try backend.performRawCall(
                    service: frame.service, method: frame.method, input: frame.payload
                )
                reply(client, status: .ok, payload: response)

                if MCPCallPolicy.isMutating(service: frame.service, method: frame.method) {
                    Task { @MainActor in
                        store.invalidateAll(origin: .helperMutation)
                        @Dependency(\.syncCoordinator) var syncCoordinator
                        syncCoordinator.requestAutomaticSync(reason: "Agent (MCP) collection change")
                    }
                }
            } catch {
                reply(
                    client,
                    status: .engineError,
                    payload: Data(error.localizedDescription.utf8)
                )
            }
        }

        private func reply(_ fd: Int32, status: MCPBridge.ResponseStatus, payload: Data) {
            let encoded = MCPBridge.encodeResponse(status: status, payload: payload)
            var sent = 0
            while sent < encoded.count {
                let count = encoded.withUnsafeBytes { buffer -> Int in
                    send(
                        fd,
                        buffer.baseAddress!.advanced(by: sent),
                        buffer.count - sent,
                        0
                    )
                }
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
#endif
