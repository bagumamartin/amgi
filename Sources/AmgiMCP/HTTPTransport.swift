import Foundation
import AnkiKit
import MCP

/// Local streamable-HTTP transport for the amgi-mcp helper.
///
/// Serves the SAME tier-filtered tool registry as stdio mode over
/// `http://127.0.0.1:<port>/mcp`, for agent apps whose UI can't speak
/// stdio.
///
/// Security posture:
///   - Loopback only (127.0.0.1) — never exposed to the network.
///   - Bearer token required; stored beside the collection root in
///     `<root>/mcp.http.json` (mode 0600) together with the effective
///     port, so the app's Settings pane can display both.
///
/// Lifecycle:
///   - Started with `amgi-mcp --http [port]`.
///   - Exits silently if a healthy instance already serves that port.
///   - Orphan watch: when the spawning process dies, this process
///     exits too, tearing the endpoint down with it.
enum LocalHTTPServer {
    static let defaultPort = 47618

    struct Endpoint: Codable {
        var port: Int
        var token: String
    }

    /// Blocking entry point — call from main()'s http branch.
    static func run(port: Int, context: EngineContext, registry: [AmgiTool]) async throws {
        // Orphan watch: exit when our spawner goes away (5 s poll).
        Thread.detachNewThread {
            while true {
                if getppid() == 1 { exit(0) }
                Thread.sleep(forTimeInterval: 5)
            }
        }

        // Duplicate guard + bind, scanning upward on collision.
        var candidate = port
        var serverFD: Int32 = -1
        for attempt in 0..<20 {
            if attempt == 0 && probeResponds(candidate: candidate) {
                FileHandle.standardError.write(
                    Data("amgi-mcp: http already served on \(candidate)\n".utf8)
                )
                exit(0)
            }
            let fd = tryBindLoopback(port: candidate)
            if fd >= 0 { serverFD = fd; break }
            candidate += 1
        }
        guard serverFD >= 0 else {
            FileHandle.standardError.write(
                Data("amgi-mcp: no free local port from \(port)\n".utf8)
            )
            exit(1)
        }
        defer { close(serverFD) }

        // Persist effective endpoint; token survives across restarts.
        let endpointFile = context.paths.directory
            .deletingLastPathComponent()
            .appendingPathComponent("mcp.http.json")
        let persisted = try? JSONDecoder().decode(
            Endpoint.self,
            from: (try? Data(contentsOf: endpointFile)) ?? Data()
        )
        let effective = Endpoint(port: candidate, token: persisted?.token ?? newToken())
        if let data = try? JSONEncoder().encode(effective) {
            try? data.write(to: endpointFile)
            chmod(endpointFile.path, 0o600)
        }
        FileHandle.standardError.write(
            Data("amgi-mcp: http listening on 127.0.0.1:\(candidate)/mcp\n".utf8)
        )

        // Same handlers as stdio mode — use a fully permissive pipeline.
        // Desktop clients vary wildly: Electron sends Origin: file:// or
        // tauri://localhost, many send Accept: */* or no Accept at all,
        // and some omit Content-Type on GET. The default pipeline would
        // 400/406 them, which the user sees as “connection closed”.
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        let server = Server(
            name: "amgi",
            version: AmgiMCPMain.version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalog.definitions(for: context.settings.tier))
        }
        await server.withMethodHandler(CallTool.self) { params in
            await ToolDispatcher.dispatch(
                toolNamed: params.name,
                arguments: params.arguments,
                context: context,
                registry: registry
            )
        }
        try await server.start(transport: transport)

        // Accept loop — sequential by design (single user, localhost).
        while true {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { continue }
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handleConnection(client, transport: transport, settingsPath: settingsPath(for: context))
            close(client)
        }
    }

    static func settingsPath(for context: EngineContext) -> String {
        context.paths.directory
            .deletingLastPathComponent()
            .appendingPathComponent("mcp.json").path
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Anything answering on the port ⇒ we're a duplicate supervisor run.
    private static func probeResponds(candidate: Int) -> Bool {
        guard let fd = connectTCPLoopback(port: candidate) else { return false }
        defer { close(fd) }
        let get = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        send(fd, get, get.utf8.count, 0)
        var buf = [UInt8](repeating: 0, count: 256)
        return recv(fd, &buf, buf.count, 0) > 0
    }

    private static func connectTCPLoopback(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    private static func tryBindLoopback(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - One connection → one request/response

    private static func handleConnection(
        _ fd: Int32,
        transport: StatelessHTTPServerTransport,
        settingsPath: String
    ) {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 16_384)

        // Header block.
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &scratch, scratch.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: scratch[0..<n])
            if buffer.count > 64 * 1024 { return }
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            writeRawResponse(fd, status: "400 Bad Request", headers: [:], body: Data())
            return
        }
        let method = String(parts[0]).uppercased()

        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            headers[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
                String(kv[1]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["Content-Length"] ?? "0") ?? 0
        guard contentLength <= 10 * 1024 * 1024 else {
            writeRawResponse(fd, status: "413 Payload Too Large", headers: [:], body: Data())
            return
        }
        let consumed = headerEnd.upperBound - buffer.startIndex
        while buffer.count - consumed < contentLength {
            let n = recv(fd, &scratch, scratch.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: scratch[0..<n])
        }
        let bodyStart = buffer.startIndex + consumed
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        // Live kill-switch: refuse everything when disabled.
        guard MCPSettings.load(from: settingsPath).enabled else {
            let body = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"The agent server is switched off in Amgi settings."}}"#
            writeRawResponse(fd, status: "503 Service Unavailable",
                             headers: ["Content-Type": "application/json"],
                             body: Data(body.utf8))
            return
        }

        // Bearer-token gate. Token lives beside the collection root;
        // anything that can read that directory is trusted by design.
        let endpointFile = URL(fileURLWithPath: settingsPath)
            .deletingLastPathComponent()
            .appendingPathComponent("mcp.http.json").path
        if let data = FileManager.default.contents(atPath: endpointFile),
           let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
           headers["Authorization"] != "Bearer \(endpoint.token)" {
            writeRawResponse(fd, status: "401 Unauthorized",
                             headers: ["Content-Type": "application/json",
                                       "WWW-Authenticate": "Bearer"],
                             body: Data(#"{"error":"unauthorized"}"#.utf8))
            return
        }

        guard method == "POST" else {
            writeRawResponse(fd, status: "405 Method Not Allowed",
                             headers: ["Allow": "POST"], body: Data())
            return
        }

        // Hand off to the SDK's stateless handler on a task (it awaits
        // internal futures); hold this connection open until the
        // response is fully written, THEN close.
        let request = MCP.HTTPRequest(method: method, headers: headers, body: body, path: "/mcp")
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let response = await transport.handleRequest(request)
            serialize(response, to: fd)
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - Response serialization

    private static func serialize(_ response: MCP.HTTPResponse, to fd: Int32) {
        switch response {
        case .accepted(let headers):
            writeRawResponse(fd, status: "202 Accepted", headers: headers, body: Data())
        case .ok(let headers):
            writeRawResponse(fd, status: "200 OK", headers: headers, body: Data())
        case .data(let data, let headers):
            var finalHeaders = headers
            if finalHeaders["Content-Type"] == nil && finalHeaders["content-type"] == nil {
                finalHeaders["Content-Type"] = "application/json"
            }
            writeRawResponse(fd, status: "200 OK", headers: finalHeaders, body: data)
        case .stream:
            // Stateless mode answers JSON directly; streams are unused.
            writeRawResponse(fd, status: "500 Internal Server Error",
                             headers: [:], body: Data("unexpected stream response".utf8))
        case .error(let statusCode, _, _, _):
            // .error builds its own JSON-RPC error body — reuse it.
            let body = response.bodyData ?? Data()
            var out = "HTTP/1.1 \(statusCode) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (k, v) in response.headers where k.lowercased() != "content-type" {
                out += "\(k): \(v)\r\n"
            }
            writeRawBytes(fd, out + "\r\n", body)
        }
    }

    private static func writeRawResponse(
        _ fd: Int32, status: String, headers: [String: String], body: Data
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        writeRawBytes(fd, head, body)
    }

    private static func writeRawBytes(_ fd: Int32, _ head: String, _ body: Data) {
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = send(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
