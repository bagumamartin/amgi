#if os(macOS)
import AnkiBackend
import AnkiKit
import Dependencies
import Foundation

/// Unix-socket bridge that lets amgi-mcp execute RPCs against THIS
/// process's live engine while the app is running. This is what makes
/// agents and Amgi work simultaneously: rslib serializes collection
/// access, so instead of fighting it, whichever process owns the engine
/// serves the other. When the app quits, its socket vanishes and the
/// helper falls back to opening the collection directly.
///
/// Protocol: AnkiKit.MCPBridge framing. Stateless per connection — one
/// request, one response, close. The helper probes the socket before
/// every tool call, so lifecycle flips are transparent to agents.
///
/// Threading: the accept loop BLOCKS forever, so it owns a dedicated
/// Foundation thread. (A `Task { }` from App.init would inherit the
/// MainActor and hang the app at launch — learned the hard way.)
/// The master switch in Settings → Agent is honored live: each new
/// connection re-reads mcp.json and is refused when disabled.
enum MCPBridgeServer {
    /// Methods whose success should refresh the app's UI state. Mirrors
    /// the mutating tools in Sources/AmgiMCP/Tools (see the service
    /// index audit in memory/decisions.md).
    private static let mutatingCalls: Set<UInt64> = {
        func key(_ service: UInt32, _ method: UInt32) -> UInt64 {
            (UInt64(service) << 32) | UInt64(method)
        }
        return [
            key(25, 1),   // notes.addNote
            key(25, 5),   // notes.updateNotes
            key(25, 7),   // notes.removeNotes
            key(43, 7),   // tags.addNoteTags
            key(43, 8),   // tags.removeNoteTags
            key(5, 4),    // cards.setFlag
            key(5, 2),    // cards.removeCards
            key(7, 1),    // decks.addDeck
            key(7, 18),   // decks.renameDeck
            key(7, 16),   // decks.removeDecks
            key(39, 1),   // media.addMediaFile
            key(9, 2),    // config.setConfigJsonNoUndo
            key(3, 8),    // collectionOps.undo
        ]
    }()

    /// Called once from App.init after prepareDependencies — on the main
    /// actor, where dependency resolution sees the opened backend.
    static func start() {

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

            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                serve(client: client)
                close(client)
            }
        }

        private func serve(client: Int32) {
            // Kill switch honored live: refuse connections when disabled.
            let settings = MCPSettings.load(
                from: CollectionLayout.rootDirectory().appendingPathComponent("mcp.json").path
            )
            guard settings.enabled else {
                reply(client, status: .unavailable, payload: Data("The agent server is switched off in Amgi settings.".utf8))
                return
            }

            var buffer = Data()
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while true {
                if let parsed = try? MCPBridge.decodeFrame(from: buffer), parsed.consumed > 0 {
                    buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + parsed.consumed)
                    handleFrame(parsed.frame, client: client)
                    continue
                }
                let n = recv(client, &scratch, scratch.count, 0)
                if n <= 0 { return }  // EOF or error → done with this client
                buffer.append(contentsOf: scratch[0..<n])
                if buffer.count > 32 * 1_024 * 1_024 { return }  // abusive client
            }
        }

        private func handleFrame(_ frame: MCPBridge.Frame, client: Int32) {
            // App-level sentinel service (ping + session state) never
            // touches the engine — answered from process state.
            if frame.service == MCPBridge.pingService {
                if frame.method == MCPBridge.sessionStateMethod {
                    if let payload = ReviewSessionContext.shared.encodedSnapshot() {
                        reply(client, status: .ok, payload: payload)
                    } else {
                        reply(
                            client, status: .unavailable,
                            payload: Data("No active review session — open Amgi and start reviewing.".utf8)
                        )
                    }
                } else {
                    // Ping or any future sentinel: bare ok.
                    reply(client, status: .ok, payload: Data())
                }
                return
            }

            do {
                let response = try backend.performRawCall(
                    service: frame.service, method: frame.method, input: frame.payload
                )
                reply(client, status: .ok, payload: response)

                if frame.mutates || Self.isMutating(frame) {
                    Task { @MainActor in
                        store.invalidateAll(origin: .helperMutation)
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
            encoded.withUnsafeBytes { buf in
                _ = send(fd, buf.baseAddress, buf.count, 0)
            }
        }

        private static func isMutating(_ frame: MCPBridge.Frame) -> Bool {
            mutatingCalls.contains((UInt64(frame.service) << 32) | UInt64(frame.method))
        }
    }
}
#endif
