public import Foundation
public import SwiftUI

/// Persisted chat scope. New chats inherit this snapshot; resumed chats retain it.
public struct AssistantContext: Codable, Hashable, Sendable {
    public var kind: String
    public var title: String
    public var reference: String
    public var deckID: Int64?
    public var noteID: Int64?
    public init(title: String = "Collection", reference: String = "", deckID: Int64? = nil, noteID: Int64? = nil, kind: String = "collection") {
        self.kind = kind; self.title = title; self.reference = reference; self.deckID = deckID; self.noteID = noteID
    }
}

public enum AssistantRoute: Sendable {
    case section(String), settings, sync, importFile, exportCollection, browse(String), review(Int64)
}

public struct AssistantScreenContextKey: PreferenceKey {
    public static var defaultValue: AssistantContext? { nil }
    public static func reduce(value: inout AssistantContext?, nextValue: () -> AssistantContext?) { if let next = nextValue() { value = next } }
}

public struct AssistantSceneNavigation: Sendable {
    public let route: @MainActor @Sendable (AssistantRoute) -> Void
    public let note: @MainActor @Sendable (AssistantCitation) -> Void
    public init(route: @escaping @MainActor @Sendable (AssistantRoute) -> Void = { _ in }, note: @escaping @MainActor @Sendable (AssistantCitation) -> Void = { _ in }) {
        self.route = route; self.note = note
    }
}
private struct AssistantSceneNavigationKey: EnvironmentKey {
    static let defaultValue = AssistantSceneNavigation()
}
/// Opens the scene's assistant with a context — through the root's own
/// presenter, so a screen that hides the global Ask AI entry (the readers)
/// gets the same sheet or floating panel instead of presenting its own.
/// Always equal: the action is stable, and a fresh closure on every root
/// body pass would otherwise invalidate every reader that reads it.
public struct AssistantOpener: Equatable {
    public let open: @MainActor (AssistantContext) -> Void
    public init(_ open: @escaping @MainActor (AssistantContext) -> Void) { self.open = open }
    public static func == (_: Self, _: Self) -> Bool { true }
}

public extension EnvironmentValues {
    /// `nil` outside the app root (previews, tests): entry points hide.
    @Entry var assistantOpener: AssistantOpener? = nil

    var assistantSceneNavigation: AssistantSceneNavigation {
        get { self[AssistantSceneNavigationKey.self] }
        set { self[AssistantSceneNavigationKey.self] = newValue }
    }
}
