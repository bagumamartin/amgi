import Foundation
import Testing
@testable import AnkiKit

@Suite("MCP bridge framing")
struct MCPBridgeTests {
    @Test func frameRoundTripsProfileAndPayload() throws {
        let frame = MCPBridge.Frame(
            service: 25,
            method: 5,
            profileID: "medical-日本語",
            payload: Data([0, 1, 2, 255])
        )

        let encoded = MCPBridge.encode(frame)
        let decoded = try #require(MCPBridge.decodeFrame(from: encoded))

        #expect(decoded.frame == frame)
        #expect(decoded.consumed == encoded.count)
    }

    @Test func partialFrameWaitsForRemainingBytes() throws {
        let encoded = MCPBridge.encode(MCPBridge.Frame(
            service: 7,
            method: 1,
            profileID: "default",
            payload: Data("deck".utf8)
        ))

        #expect(try MCPBridge.decodeFrame(from: encoded.dropLast()) == nil)
    }

    @Test func emptyProfileIsRejected() throws {
        let encoded = MCPBridge.encode(MCPBridge.Frame(
            service: 0,
            method: 0,
            profileID: "",
            payload: Data()
        ))

        #expect(throws: MCPBridgeError.self) {
            try MCPBridge.decodeFrame(from: encoded)
        }
    }

    @Test func unrelatedAndStaleProtocolsAreRejected() throws {
        var unrelated = MCPBridge.encode(MCPBridge.Frame(
            service: 0,
            method: 0,
            profileID: "default",
            payload: Data()
        ))
        unrelated[unrelated.startIndex] ^= 0xff
        #expect(throws: MCPBridgeError.self) {
            try MCPBridge.decodeFrame(from: unrelated)
        }

        var stale = MCPBridge.encode(MCPBridge.Frame(
            service: 0,
            method: 0,
            profileID: "default",
            payload: Data()
        ))
        stale.replaceSubrange(4..<8, with: [2, 0, 0, 0])
        #expect(throws: MCPBridgeError.self) {
            try MCPBridge.decodeFrame(from: stale)
        }
    }

    @Test func callPolicyDistinguishesReadsWritesAndDeletes() {
        #expect(MCPCallPolicy.requiredTier(service: 5, method: 0) == .readOnly)
        #expect(MCPCallPolicy.requiredTier(service: 25, method: 5) == .safeWrite)
        #expect(MCPCallPolicy.requiredTier(service: 25, method: 7) == .full)
        #expect(MCPCallPolicy.requiredTier(service: 45, method: 7) == .safeWrite)
        #expect(MCPCallPolicy.requiredTier(service: 41, method: 1) == .safeWrite)
        #expect(MCPCallPolicy.requiredTier(service: 999, method: 999) == nil)
        #expect(MCPCallPolicy.isMutating(service: 7, method: 18))
        #expect(!MCPCallPolicy.isMutating(service: 7, method: 2))
    }
}
