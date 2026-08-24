import AppIntents
import Foundation

/// Donates the app's actions to Spotlight, Siri, and Apple Intelligence.
///
/// No study-domain AssistantSchema exists upstream, so exposure rides the
/// generic donation pathway: exact-phrase Siri invocations, Spotlight
/// suggestions, and Shortcuts automations. Phrases use
/// `\(.applicationName)` so they localize with the app name.
struct AmgiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DueCountIntent(),
            phrases: [
                "due count in \(.applicationName)",
                "how much is due in \(.applicationName)",
            ],
            shortTitle: "Due Count",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: StartReviewIntent(),
            phrases: [
                "start review in \(.applicationName)",
                "review cards in \(.applicationName)",
            ],
            shortTitle: "Start Review",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: [
                "add a card in \(.applicationName)",
                "quick capture in \(.applicationName)",
            ],
            shortTitle: "Quick Add Card",
            systemImageName: "plus.square.on.square"
        )
        AppShortcut(
            intent: SearchNotesIntent(),
            phrases: [
                "search notes in \(.applicationName)",
            ],
            shortTitle: "Search Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "sync \(.applicationName)",
            ],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: OpenDeckIntent(),
            phrases: [
                "open \(\.$deck) in \(.applicationName)",
            ],
            shortTitle: "Open Deck",
            systemImageName: "rectangle.stack"
        )
    }
}
