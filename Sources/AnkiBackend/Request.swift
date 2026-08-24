public import Foundation

/// Typed RPC envelope. `AnkiProtoBridge` constructs these via factory
/// methods; service code consumes them via `AnkiBackend.invoke(_:)`. The
/// `decode` closure encapsulates the protobuf response type so callers
/// never see `Anki_*` symbols.
///
/// `encode` is evaluated by `invoke` at dispatch time — *not* at
/// factory-call time. This means:
///   - Encoding errors propagate cleanly (no silent `Data()` fallback).
///   - Time-sensitive fields (`Date()` timestamps in answer payloads)
///     reflect when the RPC is sent, not when the `Request` was built.
public struct Request<Response: Sendable>: Sendable {
    /// Read access is required by the amgi-mcp IPC bridge: the helper
    /// forwards (service, method, encoded-body) triples to whichever
    /// process owns the engine (the app via unix socket, or its own
    /// backend when the app is closed).
    public let serviceId: UInt32
    public let methodId: UInt32
    let encode: @Sendable () throws -> Data
    /// Public for the IPC bridge: the proxy decodes raw response bytes
    /// into the typed response without knowing the protobuf shape.
    public let decode: @Sendable (Data) throws -> Response

    package init(
        serviceId: UInt32,
        methodId: UInt32,
        encode: @escaping @Sendable () throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Response
    ) {
        self.serviceId = serviceId
        self.methodId = methodId
        self.encode = encode
        self.decode = decode
    }

    /// Convenience for factories with no request body (proto3 default).
    package static func empty(
        serviceId: UInt32,
        methodId: UInt32,
        decode: @escaping @Sendable (Data) throws -> Response
    ) -> Self {
        Self(
            serviceId: serviceId,
            methodId: methodId,
            encode: { Data() },
            decode: decode
        )
    }

    /// Materializes the request body. Public for the IPC bridge (same
    /// rationale as the identifiers); production callers go through
    /// `AnkiBackend.invoke(_:)`, which runs the encoder lazily at
    /// dispatch time so timestamped fields reflect send time.
    public var body: Data {
        get throws { try encode() }
    }
}
