public import AppIntents
import AmgiAppCore
public import AmgiAppShared
import AnkiKit
import Foundation

public struct IjukaAutomationIntentsPackage: AppIntentsPackage {}

// MARK: - Open note

public struct OpenNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Note"
    public static let description = IntentDescription("Opens an Ijuka note in Browse.")
    public static let openAppWhenRun = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    @Parameter(title: "Note")
    public var note: NoteEntity

    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = AccountStore.shared.selectedContext
        let noteID = try note.resolvedNoteID(currentProfileID: current.id)
        AppNavigationCoordinator.shared.submit(.openNote(noteID: noteID.rawValue), profile: current)
        try requireUnchangedProfile(current)
        return .result(dialog: "Opening \(note.systemDisplayTitle)…")
    }
}

// MARK: - Search in app

/// Back-deployable search action for the current iOS/macOS floor.
public struct SearchIjukaIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search Ijuka"
    public static let description = IntentDescription("Searches notes and cards in Ijuka.")
    public static let openAppWhenRun = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    @Parameter(
        title: "Search",
        requestValueDialog: "What should I search for in Ijuka?"
    )
    public var query: String

    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AutomationIntentError.emptySearch }
        let profile = AccountStore.shared.selectedContext
        AppNavigationCoordinator.shared.submit(.browse(query: trimmed), profile: profile)
        try requireUnchangedProfile(profile)
        return .result(dialog: "Searching Ijuka for \(trimmed)…")
    }
}

/// iOS 27 / macOS 27 system schema. This lets Siri hand structured in-app
/// search criteria to Ijuka while the custom intent above preserves older OS
/// support.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
public struct SystemSearchInAppIntent {
    public static let title: LocalizedStringResource = "Search Ijuka"
    public static let description = IntentDescription("Searches notes and cards in Ijuka.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    @Parameter(title: "Search")
    public var criteria: StringSearchCriteria

    public static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let query = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw AutomationIntentError.emptySearch }
        let profile = AccountStore.shared.selectedContext
        AppNavigationCoordinator.shared.submit(.browse(query: query), profile: profile)
        try requireUnchangedProfile(profile)
        return .result()
    }
}

// MARK: - Study assistant

public struct AskStudyAssistantIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask Study Assistant"
    public static let description = IntentDescription(
        "Opens Ijuka's private, on-device study assistant."
    )
    public static let openAppWhenRun = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    @Parameter(
        title: "Question",
        requestValueDialog: "What would you like to ask your study assistant?"
    )
    public var question: String

    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AutomationIntentError.emptyQuestion }
        let profile = AccountStore.shared.selectedContext
        AppNavigationCoordinator.shared.submit(.studyAssistant(prompt: prompt), profile: profile)
        try requireUnchangedProfile(profile)
        return .result(dialog: "Opening Study Assistant…")
    }
}

enum AutomationIntentError: LocalizedError {
    case emptySearch
    case emptyQuestion
    case profileChanged

    var errorDescription: String? {
        switch self {
        case .emptySearch: "Enter something to search for."
        case .emptyQuestion: "Enter a question for Study Assistant."
        case .profileChanged: "The active profile changed. Try the action again."
        }
    }
}

@MainActor
private func requireUnchangedProfile(_ expected: ProfileContext) throws {
    guard AccountStore.shared.selectedContext == expected else {
        throw AutomationIntentError.profileChanged
    }
}

// MARK: - Shortcuts

struct AutomationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchIjukaIntent(),
            phrases: [
                "search \(.applicationName)",
                "search my cards in \(.applicationName)",
            ],
            shortTitle: "Search Ijuka",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: AskStudyAssistantIntent(),
            phrases: [
                "ask \(.applicationName)",
                "ask my study assistant in \(.applicationName)",
            ],
            shortTitle: "Ask Study Assistant",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "open \(\.$note) in \(.applicationName)",
            ],
            shortTitle: "Open Note",
            systemImageName: "note.text"
        )
    }
}
