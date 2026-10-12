import Foundation
import Testing
@testable import AnkiKit

@Suite("MCP app-running policy")
struct MCPSettingsTests {
    @Test func allowingChangesDoesNotBlockTheRunningApp() throws {
        var settings = MCPSettings.default
        #expect(settings.allowsWritesWhileAppRunning)
        settings.allowsWritesWhileAppRunning = false
        #expect(settings.blockWritesWhileAppRunning)
        settings.allowsWritesWhileAppRunning = true
        let data = try JSONEncoder().encode(settings)
        let persisted = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(persisted?["blockWritesWhileAppRunning"] as? Bool == false)
        #expect(try JSONDecoder().decode(MCPSettings.self, from: data).allowsWritesWhileAppRunning)
    }

    @Test func existingExplicitBlockRemainsAnOptOut() throws {
        let data = Data(#"{"enabled":true,"tier":"safeWrite","blockWritesWhileAppRunning":true,"snapshotsBeforeDestructive":true}"#.utf8)
        let settings = try JSONDecoder().decode(MCPSettings.self, from: data)
        #expect(!settings.allowsWritesWhileAppRunning)
        #expect(settings.tier == .safeWrite)
    }
}
