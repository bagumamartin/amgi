import AmgiAppCore
import Foundation
import FoundationModels
import ManifoldKit
import Testing
@testable import AssistantFeature

@Suite("Apple tool intent boundary") @MainActor
struct NativeIntentTests {
    @Test func firstIntentNotifiesEvenWhenSelectedBeforeTheHandlerIsInstalled() async {
        let box = NativeIntentBox()
        box.append(ToolCall(id: "first", toolName: "read_collection", arguments: #"{"action":"decks"}"#))
        await withCheckedContinuation { continuation in
            box.onIntent { continuation.resume() }
        }
        box.append(ToolCall(id: "late", toolName: "change_collection", arguments: #"{"action":"undo"}"#))
        #expect(box.calls.map(\.id) == ["first"], "A native pass hands off one intent before further planning")
    }
    @Test func nativeSelectionHandsOffWithoutAuthorizingAWrite() async throws {
        let host = AssistantToolHost(profile: AccountStore.shared.selectedContext)
        let box = NativeIntentBox()
        let tool = try NativeIntentTool(definition: AssistantCollectionTool(host: host, writes: true).definition, box: box)
        let args = try GeneratedContent(json: #"{"action":"edit_note","ids":[1234567890123],"fields":["front","back"]}"#)
        await #expect(throws: (any Error).self) { try await tool.call(arguments: args) }
        #expect(host.pendingTitle == nil, "Native selection must not start approval or touch the collection")
        let call = try #require(box.calls.first)
        #expect(call.toolName == "change_collection")
        let decoded = try JSONDecoder().decode(AssistantToolArguments.self, from: Data(call.arguments.utf8))
        #expect(decoded.ids == [1234567890123])
        #expect(decoded.fields == ["front", "back"])
        // Manifold's approval gate has not run, so execution remains forbidden.
        await #expect(throws: (any Error).self) { try await host.change(decoded) }
    }
    @Test func allAdvertisedSchemasBuildForNativeSelection() throws {
        let host = AssistantToolHost(profile: AccountStore.shared.selectedContext)
        let box = NativeIntentBox()
        _ = try NativeIntentTool(definition: AssistantCollectionTool(host: host, writes: false).definition, box: box)
        _ = try NativeIntentTool(definition: AssistantCollectionTool(host: host, writes: true).definition, box: box)
        _ = try NativeIntentTool(definition: AssistantNavigationTool(host: host).definition, box: box)
        #expect(box.calls.isEmpty)
    }
    @Test func completedToolResultsReplayAsNativeToolEntries() throws {
        let call = ToolCall(id: "read-1", toolName: "read_collection", arguments: #"{"action":"decks"}"#)
        let lowered = try AssistantFoundationBackend.lower(history: [
            StructuredMessage(role: "user", parts: [.text("List my decks")]),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [.toolResult(ToolResult(callId: call.id, content: "Default, ID 1"))]),
        ], fallback: "")
        #expect(lowered.entries.count == 3)
        guard case .toolCalls(let calls) = lowered.entries[1], case .toolOutput(let output) = lowered.entries[2] else {
            Issue.record("Completed tools must not be recast as plain assistant/user text"); return
        }
        #expect(calls.first?.toolName == "read_collection")
        #expect(output.id == call.id && output.toolName == "read_collection")
    }
    @Test func savedInterleavedToolPartsRetainOrderAndOnlyReuseWithinTheirTurn() async throws {
        let call = ToolCall(id: "saved-read", toolName: "read_collection", arguments: #"{"action":"decks"}"#)
        let result = ToolResult(callId: call.id, content: #"[{"id":1,"name":"Default"}]"#)
        let pending = [StructuredMessage(role: "user", parts: [.text("List decks")]),
                       StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
                       StructuredMessage(role: "tool", parts: [.toolResult(result)])]
        let host = AssistantToolHost(profile: AccountStore.shared.selectedContext)
        let box = NativeIntentBox(history: pending)
        let tool = try NativeIntentTool(definition: AssistantCollectionTool(host: host, writes: false).definition, box: box)
        #expect(try await tool.call(arguments: GeneratedContent(json: call.arguments)) == result.content)
        #expect(box.calls.isEmpty, "Replaying a completed result must never dispatch another operation")
        let saved = [pending[0], StructuredMessage(role: "assistant", parts: [.toolCall(call), .toolResult(result), .text("Default")]), StructuredMessage(role: "user", parts: [.text("Read again")])]
        let lowered = try AssistantFoundationBackend.lower(history: saved, fallback: "")
        #expect(lowered.entries.count == 4)
        guard case .toolCalls = lowered.entries[1], case .toolOutput = lowered.entries[2], case .response = lowered.entries[3] else {
            Issue.record("Saved tool parts must retain call, result, then answer order"); return
        }
        #expect(NativeIntentBox(history: saved).completedOutput(name: call.toolName, arguments: call.arguments) == nil)
    }
}
