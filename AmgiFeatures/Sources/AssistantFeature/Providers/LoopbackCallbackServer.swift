import Foundation
import Network

/// A one-shot HTTP listener on `127.0.0.1` that catches an OAuth redirect.
///
/// OpenAI's open-source Sign in with ChatGPT flow only accepts loopback
/// redirect URIs. The browser sheet lands here; the server records the query
/// and answers with a redirect to `finishURL` — a custom scheme the
/// in-app web authentication session is waiting for — so the sheet closes
/// by itself on iOS as well as macOS.
final class LoopbackCallbackServer: @unchecked Sendable {
    struct Callback: Sendable { let items: [String: String] }

    let port: UInt16
    let path: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ijuka.assistant.oauth-loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, any Error>?
    private var received: Result<Callback, any Error>?
    private let finishURL: URL

    var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    /// Binds the first free port of `ports`; only the port may differ
    /// between sign-ins, so the path stays fixed.
    init(ports: [UInt16], path: String, finishURL: URL) async throws {
        self.path = path
        self.finishURL = finishURL
        var lastError: (any Error)?
        for candidate in ports {
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: candidate) ?? .any)
                let listener = try NWListener(using: parameters)
                // A listener needs its connection handler before it starts;
                // the server isn't initialized yet, so route through a box.
                let router = ConnectionRouter()
                listener.newConnectionHandler = { router.accept?($0) }
                try await Self.start(listener, on: queue)
                self.listener = listener
                self.port = listener.port?.rawValue ?? candidate
                router.accept = { [weak self] connection in self?.accept(connection) ?? connection.cancel() }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    deinit { listener.cancel() }

    /// Waits for the browser to hit the callback path.
    func callback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let received {
                    lock.unlock()
                    continuation.resume(with: received)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<Callback, any Error>) {
        lock.lock()
        guard received == nil else { lock.unlock(); return }
        received = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    private static func start(_ listener: NWListener, on queue: DispatchQueue) async throws {
        let box = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.run { continuation.resume() }
                case .failed(let error): box.run { continuation.resume(throwing: error) }
                case .cancelled: box.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://127.0.0.1\(target)"), components.path == self.path else {
                self.respond(connection, status: "404 Not Found", location: nil)
                return
            }
            var items: [String: String] = [:]
            for item in components.queryItems ?? [] { items[item.name] = item.value ?? "" }
            self.respond(connection, status: "302 Found", location: self.finishURL.absoluteString)
            self.finish(.success(Callback(items: items)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, location: String?) {
        let body = "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\">You can return to Ijuka.</body></html>"
        var head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let location { head += "Location: \(location)\r\n" }
        connection.send(content: Data((head + "\r\n" + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ConnectionRouter: @unchecked Sendable {
    var accept: ((NWConnection) -> Void)?
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
