public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct TagClient: Sendable {
    public var getAllTags: @Sendable () async throws -> [String]
    public var addTag: @Sendable (_ tag: String) async throws -> Void
    public var addTagToNotes: @Sendable (_ tag: String, _ noteIDs: [NoteID]) async throws -> Void
    public var removeTagFromNotes: @Sendable (_ tag: String, _ noteIDs: [NoteID]) async throws -> Void
    public var removeTag: @Sendable (_ tag: String) async throws -> Void
    public var renameTag: @Sendable (_ oldName: String, _ newName: String) async throws -> Void
    public var findAndReplaceTag: @Sendable (_ noteIds: [NoteID], _ search: String, _ replacement: String, _ regex: Bool, _ matchCase: Bool) async throws -> Void
    public var completeTag: @Sendable (_ input: String) async throws -> [String]
    public var tagTree: @Sendable () async throws -> TagTreeNodeData
    public var reparentTags: @Sendable (_ tags: [String], _ newParent: String) async throws -> Void
    public var setCollapsed: @Sendable (_ tag: String, _ collapsed: Bool) async throws -> Void
}

extension TagClient: TestDependencyKey {
    public static let testValue = TagClient()
}

extension DependencyValues {
    public var tagClient: TagClient {
        get { self[TagClient.self] }
        set { self[TagClient.self] = newValue }
    }
}
