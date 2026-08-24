import Foundation
import AnkiKit

/// Forwards RPCs to Amgi.app over the unix-socket bridge (bridged mode:
/// the app is running, holds the engine, and applies changes through its
/// live UI stack — true simultaneous operation). One connection per
/// call keeps the protocol stateless and crash recovery trivial; agent
/// traffic is sequential by nature.
enum ProxyCaller {
    /// Cheap liveness probe used before every tool call. Costs one
    /// non-blocking connect (sub-millisecond against a live app).
    ///
    /// Force-quitting the app leaves the socket FILE behind (Unix domain
    /// sockets are only auto-removed on clean close). A dead file makes
    /// connect fail with ECONNREFUSED instantly — when we see that, we
    /// unlink the corpse so the filesystem stays clean. Safe: a live
    /// listener always accepts the probe, so we never unlink a working
    /// bridge. (The app additionally unlinks before binding.)
    static func ping(socketPath: String, timeoutMs: Int32 = 250) -> Bool {
        guard let fd = connectSocket(path: socketPath, timeoutMs: timeoutMs) else { return false }
        close(fd)
        return true
    }

    /// Removes a socket file that just refused a connection.
    static func cleanStaleSocket(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return }
        unlink(path)
    }

    /// Sends one framed request and returns the decoded response.
    static func transact(
        socketPath: String, service: UInt32, method: UInt32, payload: Data
    ) throws -> (status: MCPBridge.ResponseStatus, payload: Data) {
        let frameData = MCPBridge.encode(MCPBridge.Frame(
            service: service, method: method, mutates: false, payload: payload
        ))
        let response = try sendFrame(socketPath: socketPath, frame: frameData)
        guard let decoded = try? MCPBridge.decodeResponse(from: response) else {
            throw ToolError.blocked("bridge returned a partial response")
        }
        return (decoded.status, decoded.payload)
    }

    // MARK: - Socket plumbing

    private static func sendFrame(socketPath: String, frame: Data) throws -> Data {
        guard let fd = connectSocket(path: socketPath, timeoutMs: 1_500) else {
            throw ToolError.blocked("could not connect to Amgi.app")
        }
        defer { close(fd) }

        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes { buf -> Int in
                send(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent, 0)
            }
            if n <= 0 { throw ToolError.blocked("bridge send failed") }
            sent += n
        }

        var received = Data()
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let parsed = try? MCPBridge.decodeResponse(from: received), parsed.consumed > 0 {
                return received
            }
            let n = recv(fd, &scratch, scratch.count, 0)
            if n <= 0 { throw ToolError.blocked("connection closed mid-response") }
            received.append(contentsOf: scratch[0..<n])
            if received.count > 64 * 1_024 * 1_024 {
                throw ToolError.blocked("bridge response exceeded 64 MB")
            }
        }
    }

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
