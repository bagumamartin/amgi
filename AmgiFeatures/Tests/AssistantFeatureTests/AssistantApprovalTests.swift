import AmgiAppCore
import AnkiClients
import AnkiBackend
import AnkiProtoBridge
import AnkiServices
import AnkiKit
import Dependencies
import Foundation
import ManifoldKit
import Testing
@testable import AssistantFeature

@Suite("Assistant reviewed changes", .serialized) @MainActor
struct AssistantApprovalTests {
    @Test func fieldContentsContractRetainsLegacyDecodingAndRejectsDroppedContent() async throws {
        let current = try JSONDecoder().decode(AssistantToolArguments.self, from: Data(#"{"action":"add_note","fieldContents":["question","answer"]}"#.utf8))
        let legacy = try JSONDecoder().decode(AssistantToolArguments.self, from: Data(#"{"action":"add_note","fields":["question","answer"]}"#.utf8))
        #expect(current == legacy && current.fields == ["question", "answer"])
        let host = AssistantToolHost(profile: AccountStore.shared.selectedContext)
        let result = await host.approve(ToolCall(id: "misplaced-content", toolName: "change_collection", arguments: #"{"action":"add_note","fieldContents":["Front","Back"],"value":"must not be discarded"}"#))
        #expect(result != .approved && host.pendingTitle == nil)
    }
    @Test func listReadsExposeExactJSONIDsAndRejectWriteOnlyArguments() async throws {
        let exactID: Int64 = 9_007_199_254_740_993
        let host = withDependencies {
            $0.notetypesClient.listAll = { [NotetypeNameId(id: NotetypeID(exactID), name: "Basic")] }
        } operation: { AssistantToolHost(profile: AccountStore.shared.selectedContext) }
        let registry = AssistantToolCatalog.registry(host: host)
        registry.validator = JSONSchemaValidator()
        let result = await registry.dispatch(ToolCall(id: "list-types", toolName: "read_collection", arguments: #"{"action":"list_notetypes"}"#))
        #expect(!result.isError && result.content.contains("\"id\":9007199254740993"))
        let invalid = await registry.dispatch(ToolCall(id: "read-fields", toolName: "read_collection", arguments: #"{"action":"list_notetypes","fields":["id"]}"#))
        #expect(invalid.isError, "Read schemas must reject invented write-only arguments")
    }
    @Test func providerNeutralJSONDispatchCannotBypassApproval() async throws {
        let host = AssistantToolHost(profile: AccountStore.shared.selectedContext)
        let receiptsBefore = host.receipts.count
        let registry = AssistantToolCatalog.registry(host: host)
        // A remote/local adapter emits the same plain JSON calls, with no
        // Foundation Models session, native schema or Apple intent involved.
        let read = await registry.dispatch(ToolCall(id: "api-read", toolName: "read_collection", arguments: #"{"action":"capabilities"}"#))
        #expect(read.callId == "api-read" && !read.isError)
        let write = await registry.dispatch(ToolCall(id: "api-write", toolName: "change_collection", arguments: #"{"action":"create_deck","name":"must not be created"}"#))
        #expect(write.callId == "api-write" && write.isError)
        #expect(host.pendingTitle == nil && host.receipts.count == receiptsBefore)
    }
    private func record(fields: String = "front\u{1f}back") -> NoteRecord {
        NoteRecord(id: NoteID(5), guid: "fixture", mid: NotetypeID(7), mod: 1, flds: fields, sfld: "front", csum: 0)
    }
    @Test func declineAndCancellationNeverAuthorizeWrites() async throws {
        let note = record()
        let host = withDependencies {
            $0.noteClient.fetch = { _ in note }
            $0.cardClient.fetchByNote = { _ in [] }
        } operation: { AssistantToolHost(profile: AccountStore.shared.selectedContext) }
        let args = AssistantToolArguments(action: "edit_note", ids: [5], fields: ["replacement", "back"])
        let call = ToolCall(id: "test", toolName: "change_collection", arguments: String(decoding: try JSONEncoder().encode(args), as: UTF8.self))
        let request = Task { await host.approve(call) }
        for _ in 0..<100 { if host.pendingTitle != nil { break }; await Task.yield() }
        #expect(host.pendingItems.count == 2)
        host.resolve(approve: false)
        #expect(await request.value == .denied(reason: "Change declined or interrupted"))
        await #expect(throws: (any Error).self) { try await host.change(args) }
        let second = Task { await host.approve(call) }
        for _ in 0..<100 { if host.pendingTitle != nil { break }; await Task.yield() }
        second.cancel()
        #expect(await second.value != .approved)
    }
    @Test func changedTargetsMustBeReviewedAgain() async throws {
        let source = MutableNote(record())
        let writes = WriteCounter()
        let host = withDependencies {
            $0.noteClient.fetch = { _ in await source.value }
            $0.cardClient.fetchByNote = { _ in [] }
            $0.noteClient.save = { _ in await writes.increment() }
        } operation: { AssistantToolHost(profile: AccountStore.shared.selectedContext) }
        let args = AssistantToolArguments(action: "edit_note", ids: [5], fields: ["replacement", "back"])
        let call = ToolCall(id: "test", toolName: "change_collection", arguments: String(decoding: try JSONEncoder().encode(args), as: UTF8.self))
        let request = Task { await host.approve(call) }
        for _ in 0..<100 { if host.pendingTitle != nil { break }; await Task.yield() }
        host.resolve(approve: true)
        #expect(await request.value == .approved)
        await source.replace(record(fields: "concurrent edit\u{1f}back"))
        await #expect(throws: (any Error).self) { try await host.change(args) }
        #expect(await writes.count == 0)
    }
    @Test func fieldCountMismatchCannotReachApproval() async throws {
        let note = record()
        let host = withDependencies {
            $0.noteClient.fetch = { _ in note }
            $0.cardClient.fetchByNote = { _ in [] }
        } operation: { AssistantToolHost(profile: AccountStore.shared.selectedContext) }
        let args = AssistantToolArguments(action: "edit_note", ids: [5], fields: ["only one"])
        let result = await host.approve(ToolCall(id: "bad", toolName: "change_collection", arguments: String(decoding: try JSONEncoder().encode(args), as: UTF8.self)))
        #expect(result != .approved)
        #expect(host.pendingTitle == nil)
    }
    @Test func reviewedEditCommitsAndAtomicFenceRejectsStaleSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try AnkiBackend()
        try backend.openCollection(collectionPath: directory.appendingPathComponent("collection.anki2").path, mediaFolderPath: directory.appendingPathComponent("media").path, mediaDbPath: directory.appendingPathComponent("media.db").path)
        defer { try? backend.closeCollection() }
        let names = try await backend.invoke(.notetypeNames)
        let type = try #require(names.first(where: { $0.name == "Basic" }))
        let fullType = try await backend.invoke(.notetype(for: type.id))
        let destination = try #require(try await backend.invoke(.deckNames).first(where: { $0.id.rawValue == 1 }))
        var template = try await backend.invoke(.newNote(notetypeId: type.id))
        template.fields = ["front", "back"]
        try await backend.invoke(.addNote(template: template, deckId: DeckID(1)))
        let ids = try await backend.invoke(.searchNoteIds(query: ""))
        let id = try #require(ids.first)
        let before = try await backend.invoke(.getNote(id: id))
        let cardIDs = try await backend.invoke(.cardIDsOfNote(id: id))
        let siblings = try cardIDs.map { try backend.invoke(.getCard(id: $0)) }
        let args = AssistantToolArguments(action: "edit_note", ids: [id.rawValue], fields: ["reviewed replacement", "back"])
        let expected = ["fixture", "edit_note", String(describing: before), String(describing: siblings)].joined(separator: "\n")
        let activation = try #require(backend.collectionActivationID)
        try await withDependencies {
            $0.ankiBackend = backend
            $0.notesService.getNote = { try backend.invoke(.getNote(id: $0)) }
            $0.notesService.saveNote = { try backend.invoke(.updateNote($0)) }
            $0.notesService.newNote = { try backend.invoke(.newNote(notetypeId: $0)) }
            $0.decksService.fetchAll = { [destination] }
        } operation: {
            let result = try await AssistantCollectionMutator.apply(original: args, approved: args, expected: expected, profileID: "fixture", activation: activation)
            #expect(result.targets == [id.rawValue])
            #expect(try await backend.invoke(.getNote(id: id)).flds == "reviewed replacement\u{1f}back")
            // Reusing a pre-edit snapshot must fail before any second write.
            var stale = args; stale.fields = ["must not commit", "back"]
            await #expect(throws: (any Error).self) {
                try await AssistantCollectionMutator.apply(original: stale, approved: stale, expected: expected, profileID: "fixture", activation: activation)
            }
            #expect(try await backend.invoke(.getNote(id: id)).flds == "reviewed replacement\u{1f}back")
            let draft = AssistantToolArguments(action: "add_note", deckID: 1, notetypeID: type.id.rawValue, fields: ["Front", "Back"])
            var reviewed = draft; reviewed.fields = ["Reviewed question", "Reviewed answer"]
            let addSnapshot = ["fixture", "add_note", String(describing: fullType), String(describing: destination)].joined(separator: "\n")
            let created = try await AssistantCollectionMutator.apply(original: draft, approved: reviewed, expected: addSnapshot, profileID: "fixture", activation: activation)
            let createdID = try #require(created.targets.first)
            #expect(createdID != id.rawValue && created.appliedFields == reviewed.fields)
            #expect(try await backend.invoke(.getNote(id: NoteID(createdID))).flds == "Reviewed question\u{1f}Reviewed answer")
        }
    }
}
private actor MutableNote {
    var value: NoteRecord
    init(_ value: NoteRecord) { self.value = value }
    func replace(_ value: NoteRecord) { self.value = value }
}
private actor WriteCounter { var count = 0; func increment() { count += 1 } }
