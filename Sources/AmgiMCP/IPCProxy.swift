import Foundation
import AnkiKit

/// Forwards RPCs to Amgi.app over the unix-socket bridge (bridged mode:
/// the app is running, holds the engine, and applies changes through its
/// live UI stack — true simultaneous operation). One connection is retained
/// for each complete MCP tool call, so multi-RPC tools pay setup only once
/// while separate calls remain isolated for simple crash recovery.
enum ProxyCaller {
    enum ProbeResult {
        case live(Session)
        case unavailable(String)
        case absent
    }

    final class Session: @unchecked Sendable {
        private let fd: Int32
        private let profileID: String
        private let lock = NSLock()

        init(socketPath: String, profileID: String, timeoutMs: Int32 = 120_000) throws {
            guard let fd = ProxyCaller.connectSocket(
                path: socketPath,
                timeoutMs: min(timeoutMs, 1_500)
            ) else {
                throw ToolError.blocked("could not connect to Amgi.app")
            }
            self.fd = fd
            self.profileID = profileID

            var noSigPipe: Int32 = 1
            _ = setsockopt(
                fd, SOL_SOCKET, SO_NOSIGPIPE,
                &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            )
            var timeout = timeval(
                tv_sec: Int(timeoutMs / 1_000),
                tv_usec: Int32(timeoutMs % 1_000) * 1_000
            )
            _ = setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO,
                &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))
            )
            _ = setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO,
                &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))
            )
        }

        deinit { close(fd) }

        func transact(
            service: UInt32,
            method: UInt32,
            payload: Data
        ) throws -> (status: MCPBridge.ResponseStatus, payload: Data) {
            lock.lock()
            defer { lock.unlock() }

            let frame = MCPBridge.encode(MCPBridge.Frame(
                service: service,
                method: method,
                profileID: profileID,
                payload: payload
            ))
            try sendAll(frame)
            return try receiveResponse()
        }

        private func sendAll(_ frame: Data) throws {
            var sent = 0
            while sent < frame.count {
                let count = frame.withUnsafeBytes { buffer -> Int in
                    send(
                        fd,
                        buffer.baseAddress!.advanced(by: sent),
                        buffer.count - sent,
                        0
                    )
                }
                if count <= 0 {
                    let reason = errno == EAGAIN || errno == EWOULDBLOCK
                        ? "bridge send timed out"
                        : "bridge send failed"
                    throw ToolError.blocked(reason)
                }
                sent += count
            }
        }

        private func receiveResponse() throws -> (
            status: MCPBridge.ResponseStatus,
            payload: Data
        ) {
            var received = Data()
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while true {
                if let parsed = try MCPBridge.decodeResponse(from: received) {
                    return (parsed.status, parsed.payload)
                }
                let count = recv(fd, &scratch, scratch.count, 0)
                if count <= 0 {
                    let reason = errno == EAGAIN || errno == EWOULDBLOCK
                        ? "bridge response timed out"
                        : "connection closed mid-response"
                    throw ToolError.blocked(reason)
                }
                received.append(contentsOf: scratch[0..<count])
                if received.count > 64 * 1_024 * 1_024 {
                    throw ToolError.blocked("bridge response exceeded 64 MB")
                }
            }
        }
    }

    /// Cheap liveness probe used before every tool call. Costs one
    /// non-blocking connect (sub-millisecond against a live app).
    ///
    /// Force-quitting the app leaves the socket FILE behind (Unix domain
    /// sockets are only auto-removed on clean close). A dead file makes
    /// connect fail with ECONNREFUSED instantly — when we see that, we
    /// unlink the corpse so the filesystem stays clean. Safe: a live
    /// listener always accepts the probe, so we never unlink a working
    /// bridge. (The app additionally unlinks before binding.)
    static func probe(socketPath: String, profileID: String) -> ProbeResult {
        guard let session = try? Session(
            socketPath: socketPath,
            profileID: profileID,
            timeoutMs: 250
        ), let response = try? session.transact(
            service: MCPBridge.pingService,
            method: MCPBridge.pingMethod,
            payload: Data()
        ) else { return .absent }
        switch response.status {
        case .ok: return .live(session)
        case .engineError, .unavailable:
            return .unavailable(String(decoding: response.payload, as: UTF8.self))
        }
    }

    /// Removes a socket file that just refused a connection.
    static func cleanStaleSocket(path: String) {
        // During app startup there is a tiny bind→listen interval where a
        // valid new socket may still refuse connections. Never unlink while
        // the owning app process exists; the app removes stale paths itself
        // immediately before binding.
        guard !AppRunningCheck.isAmgiRunning else { return }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return }
        unlink(path)
    }

    // MARK: - Socket plumbing

    private static func connectSocket(path: String, timeoutMs: Int32) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }

        // Non-blocking connect + poll so an absent app costs milliseconds.
        let currentFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            if errno == ECONNREFUSED {
                // Dead listener (app force-quit): sweep the file away.
                cleanStaleSocket(path: path)
                close(fd)
                return nil
            }
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var pollSet = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollSet, 1, timeoutMs) > 0 else {
                // Nothing accepted within budget. Could be a hung
                // listener — do NOT unlink a possibly-live socket.
                close(fd)
                return nil
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            guard soError == 0 else {
                if soError == ECONNREFUSED { cleanStaleSocket(path: path) }
                close(fd)
                return nil
            }
        }

        // Restore blocking mode for straightforward read/write.
        _ = fcntl(fd, F_SETFL, currentFlags)
        return fd
    }
}
