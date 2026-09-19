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
///   request  = u32 magic · u32 version · u32 service · u32 method ·
///              u32 profileLen · u32 payloadLen ·
///              profile UTF-8 · payload bytes
///   response = u8 status · u32 len · bytes
/// status: 0 = ok (bytes), 1 = engine error (UTF-8 message),
///         2 = bridge unavailable (UTF-8 message).
public enum MCPBridge {
    /// "AMGI" in little-endian byte order. Explicit identification keeps
    /// stale or unrelated local clients from being interpreted as RPCs.
    public static let magic: UInt32 = 0x4947_4D41
    public static let protocolVersion: UInt32 = 1
    public static let maximumPayloadBytes = 64 * 1_024 * 1_024

    /// Sentinel call used by the helper to detect a live bridge without
    /// touching the engine.
    public static let pingService: UInt32 = 0
    public static let pingMethod: UInt32 = 0

    /// App-level session-state request (same service-0 sentinel as ping).
    /// The app answers from its live `ReviewSession` — the card on screen,
    /// deck scope, answered-today list. Only meaningful while the app runs;
    /// the helper surfaces it as the `get_review_context` tool.
    public static let sessionStateMethod: UInt32 = 1
    /// Requests a consistent pre-destructive snapshot from the process that
    /// owns the live backend. The frame's profile id selects the collection.
    public static let snapshotMethod: UInt32 = 2

    public struct Frame: Sendable, Equatable {
        public let service: UInt32
        public let method: UInt32
        public let profileID: String
        public let payload: Data

        public init(
            service: UInt32,
            method: UInt32,
            profileID: String,
            payload: Data
        ) {
            self.service = service
            self.method = method
            self.profileID = profileID
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
        let profile = Data(frame.profileID.utf8)
        var data = Data(capacity: frame.payload.count + profile.count + 24)
        append(magic, to: &data)
        append(protocolVersion, to: &data)
        append(UInt32(frame.service), to: &data)
        append(UInt32(frame.method), to: &data)
        append(UInt32(profile.count), to: &data)
        append(UInt32(frame.payload.count), to: &data)
        data.append(profile)
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
        guard buffer.count >= 24 else { return nil }
        guard readUInt32(buffer, 0) == magic else { throw MCPBridgeError.badMagic }
        guard readUInt32(buffer, 4) == protocolVersion else {
            throw MCPBridgeError.unsupportedVersion
        }
        let service = readUInt32(buffer, 8)
        let method = readUInt32(buffer, 12)
        let profileLength = Int(readUInt32(buffer, 16))
        let payloadLength = Int(readUInt32(buffer, 20))
        guard profileLength <= 4_096, payloadLength <= maximumPayloadBytes else {
            throw MCPBridgeError.badLength
        }
        let total = 24 + profileLength + payloadLength
        guard buffer.count >= total else { return nil }
        let profileData = buffer.subdata(in: 24..<(24 + profileLength))
        guard let profileID = String(data: profileData, encoding: .utf8), !profileID.isEmpty else {
            throw MCPBridgeError.badProfile
        }
        let payloadStart = 24 + profileLength
        let payload = buffer.subdata(in: payloadStart..<total)
        return (
            Frame(
                service: service,
                method: method,
                profileID: profileID,
                payload: payload
            ),
            total
        )
    }

    public static func decodeResponse(from buffer: Data) throws -> (status: ResponseStatus, payload: Data, consumed: Int)? {
        guard buffer.count >= 5 else { return nil }
        guard let status = ResponseStatus(rawValue: buffer[buffer.startIndex]) else {
            throw MCPBridgeError.badStatus
        }
        let length = Int(readUInt32(buffer, 1))
        guard length <= maximumPayloadBytes else { throw MCPBridgeError.badLength }
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
    case badMagic
    case unsupportedVersion
    case badStatus
    case badLength
    case badProfile

    public var errorDescription: String? {
        switch self {
        case .badMagic: "not an Amgi MCP bridge frame"
        case .unsupportedVersion: "unsupported Amgi MCP bridge protocol version"
        case .badStatus: "malformed bridge response"
        case .badLength: "bridge frame length is invalid"
        case .badProfile: "bridge frame profile is invalid"
        }
    }
}
