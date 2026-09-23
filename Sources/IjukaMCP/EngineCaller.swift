import Foundation
import AnkiBackend
import AnkiKit

/// Concrete engine access handed to tool handlers. Synchronous by
/// design: handlers already run off the main thread, socket I/O blocks
/// for microseconds against a live app, and keeping `invoke` non-async
/// means the 25 existing call sites stay untouched.
struct EngineCaller: Sendable {
    enum Kind: Sendable {
        /// The app is running and owns the engine — RPCs ride the IPC bridge.
        case bridged(session: ProxyCaller.Session)
        /// This process owns the collection directly (app closed).
        case local(AnkiBackend)
    }

    let kind: Kind

    var isBridged: Bool {
        if case .bridged = kind { return true }
        return false
    }

    func snapshot(paths: CollectionPaths) throws -> URL {
        switch kind {
        case .local(let backend):
            return try backend.withExclusiveAccess {
                try CollectionSnapshotter.snapshot(
                    collectionPath: paths.collectionPath,
                    profileDirectory: paths.directory
                )
            }
        case .bridged(let session):
            let response = try session.transact(
                service: MCPBridge.pingService,
                method: MCPBridge.snapshotMethod,
                payload: Data()
            )
            guard response.status == .ok else {
                throw ToolError.blocked(String(decoding: response.payload, as: UTF8.self))
            }
            return URL(fileURLWithPath: String(decoding: response.payload, as: UTF8.self))
        }
    }

    func invoke<R>(_ request: Request<R>) throws -> R {
        switch kind {
        case .local(let backend):
            guard !AppRunningCheck.isIjukaRunning else {
                backend.requestAbort()
                throw ToolError.blocked(
                    "Ijuka.app is taking ownership of the collection; retry this call in a moment."
                )
            }
            // Direct mode races are rare (app closed ⇒ we own the file)
            // but the app's shutdown writes or a stale socket probe can
            // collide; brief retries absorb SQLITE_BUSY-style errors.
            var lastError: (any Error)?
            for attempt in 0...4 {
                do {
                    return try backend.invoke(request)
                } catch {
                    guard attempt < 4, error.localizedDescription.contains("already open") else { throw error }
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1))
                    continue
                }
            }
            if let lastError { throw lastError }
            fatalError("unreachable: retry loop exhausted without error")
        case .bridged(let session):
            let response = try session.transact(
                service: request.serviceId,
                method: request.methodId,
                payload: request.body
            )
            switch response.status {
            case .ok:
                return try request.decode(response.payload)
            case .engineError:
                throw BackendError(
                    kind: .ioError,
                    message: String(decoding: response.payload, as: UTF8.self)
                )
            case .unavailable:
                throw ToolError.blocked(String(decoding: response.payload, as: UTF8.self))
            }
        }
    }
}
