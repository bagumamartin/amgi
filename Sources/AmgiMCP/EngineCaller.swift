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
        case bridged(socketPath: String)
        /// This process owns the collection directly (app closed).
        case local(AnkiBackend)
    }

    let kind: Kind

    func invoke<R>(_ request: Request<R>) throws -> R {
        switch kind {
        case .local(let backend):
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
        case .bridged(let socketPath):
            let response = try ProxyCaller.transact(
                socketPath: socketPath,
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
