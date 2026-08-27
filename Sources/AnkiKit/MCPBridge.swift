public import Foundation

/// Wire protocol for the amgi-mcp IPC bridge — the mechanism that lets
/// AI agents and Amgi.app use the engine AT THE SAME TIME.
///
/// Ownership model: rslib holds an exclusive lock per collection, so
/// only one process may open it. When the app runs, IT owns the engine
/// and exposes this local unix-socket bridge; the helper forwards every
/// tool's RPCs to it. When the app is quit, the socket disappears and
/// the helper opens the collection directly. Either way, agents and the
/// app are never locked out of each other.
///
/// Framing (all integers little-endian):
///   request  = u32 service · u32 method · u32 flags · u32 len · bytes
///   response = u8 status · u32 len · bytes
/// flags bit0 marks a mutating call so the app can refresh its UI state.
/// status: 0 = ok (bytes), 1 = engine error (UTF-8 message),
///         2 = bridge unavailable (UTF-8 message).
public enum MCPBridge {
    /// Sentinel call used by the helper to detect a live bridge without
    /// touching the engine.
    public static let pingService: UInt32 = 0
    public static let pingMethod: UInt32 = 0

    /// App-level session-state request (same service-0 sentinel as ping).
    /// The app answers from its live `ReviewSession` — the card on screen,
    /// deck scope, answered-today list. Only meaningful while the app runs;
    /// the helper surfaces it as the `get_review_context` tool.
    public static let sessionStateMethod: UInt32 = 1

    public struct Frame: Sendable, Equatable {
        public let service: UInt32
        public let method: UInt32
        public let mutates: Bool
        public let payload: Data

        public init(service: UInt32, method: UInt32, mutates: Bool, payload: Data) {
            self.service = service
            self.method = method
            self.mutates = mutates
            self.payload = payload
        }
    }

    public enum ResponseStatus: UInt8, Sendable {
        case ok = 0
        case engineError = 1
        case unavailable = 2
    }

    public static func socketPath(
        rootDirectory environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        CollectionLayout.rootDirectory(environment: environment)
            .appendingPathComponent("mcp.sock").path
    }

    // MARK: Encoding

    public static func encode(_ frame: Frame) -> Data {
        var data = Data(capacity: frame.payload.count + 16)
        append(UInt32(frame.service), to: &data)
        append(UInt32(frame.method), to: &data)
        append(frame.mutates ? 1 : 0, to: &data)
        append(UInt32(frame.payload.count), to: &data)
        data.append(frame.payload)
        return data
    }

    public static func encodeResponse(status: ResponseStatus, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(status.rawValue)
        append(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    /// Decodes exactly one leading frame from `buffer`. Returns nil when
    /// more bytes are needed; throws on garbage.
    public static func decodeFrame(from buffer: Data) throws -> (frame: Frame, consumed: Int)? {
        guard buffer.count >= 16 else { return nil }
        let service = readUInt32(buffer, 0)
        let method = readUInt32(buffer, 4)
        let flags = readUInt32(buffer, 8)
        let length = Int(readUInt32(buffer, 12))
        guard buffer.count >= 16 + length else { return nil }
        let payload = buffer.subdata(in: 16..<(16 + length))
        return (
            Frame(service: service, method: method, mutates: flags & 1 == 1, payload: payload),
            16 + length
        )
    }

    public static func decodeResponse(from buffer: Data) throws -> (status: ResponseStatus, payload: Data, consumed: Int)? {
        guard buffer.count >= 5 else { return nil }
        guard let status = ResponseStatus(rawValue: buffer[buffer.startIndex]) else {
            throw MCPBridgeError.badStatus
        }
        let length = Int(readUInt32(buffer, 1))
        guard buffer.count >= 5 + length else { return nil }
        let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 5 + length))
        return (status, payload, 5 + length)
    }

    // MARK: Primitives

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start...].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
}

public enum MCPBridgeError: LocalizedError, Sendable {
    case badStatus

    public var errorDescription: String? { "malformed bridge response" }
}
