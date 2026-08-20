// AmgiApp/Sources/AmgiAppApp.swift
import SwiftUI
import AmgiReader
import AmgiTheme
import AmgiAppCore
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiSync
import AmgiAppShared
import Dependencies
import SyncFeature
import Foundation
import Sharing

@main
struct AnkiAppApp: App {
    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingReviewDeckId: DeckID? = nil
    @Shared(.appStorage(AppearancePreferences.Keys.appFont))
    private var appFontRaw: String = AppFont.system.rawValue

    /// Set when the collection could not be opened at launch. A plain `let`
    /// rather than `@State`: it is decided once in `init` and never changes
    /// for the lifetime of this App value.
    private let startupError: String?

    private var destination: Destination {
        onboardingCompleted ? .main : .onboarding
    }

    init() {
        // Multi-profile bootstrap: migrate legacy single-collection
        // layout into the default profile, then open the selected
        // profile's collection.
        AccountStore.migrateLegacyCollectionIfNeeded()
        let activeProfile = MainActor.assumeIsolated {
            AccountStore.shared.current
        }

        // `try!` here turned any collection-open failure into a crash inside
        // init — on every launch, permanently, with no in-app recovery. A
        // corrupt collection.anki2, a schema written by a newer Anki, or a
        // full disk left the user with delete-and-reinstall as their only
        // option, which destroys the local collection. That state is exactly
        // what an interrupted full-download or import leaves behind.
        //
        // checkDatabase() is also gone from the launch path: it is one of
        // the longest blocking calls the engine has, and running it before
        // the first frame made cold launch scale with collection size. It
        // remains available as an explicit action in Settings > Maintenance.
        var failure: String?
        do {
            try prepareDependencies {
                let backend = try AnkiBackend(preferredLangs: ["en"])
                try openCollection(for: activeProfile.id, backend: backend)
                $0.ankiBackend = backend
                $0.syncCoordinator = SyncCoordinator()
                // Wire the Anki-backed concrete realization of the dictionary
                // engine's abstract config store. Keeps the engine package
                // (AmgiReaderDictionary) free of Anki imports.
                $0.dictionaryConfigStore = AnkiBackedDictionaryConfigStore.makeStore()
            }
        } catch {
            failure = error.localizedDescription
        }
        startupError = failure
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let startupError {
                    StartupErrorView(message: startupError)
                } else {
                    switch destination {
                    case .onboarding:
                        OnboardingView()
                    case .main:
                        ContentView(pendingReviewDeckId: $pendingReviewDeckId)
                    }
                }
            }
            // Rebuild the entire view tree when the active profile changes —
            // every screen holds state derived from the previously open
            // collection.
            .id(AccountStore.shared.selectedID)
            .onChange(of: AccountStore.shared.selectedID) {
                pendingReviewDeckId = nil
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await writeWidgetSnapshot() }
                }
            }
            .onOpenURL { url in
                guard url.scheme == "amgi",
                      url.host == "review",
                      let deckIdStr = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "deckId" })?.value,
                      let deckId = Int64(deckIdStr)
                else { return }
                pendingReviewDeckId = DeckID(deckId)
            }
            .themedRoot()
            .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
        }
    }
}

private extension AnkiAppApp {
    enum Destination {
        case onboarding
        case main
    }
}

/// Creates the profile's directory layout if needed and opens its collection
/// on `backend`. Shared by the bootstrap and in-app profile switching.
@MainActor
func openCollection(for profileID: String, backend: AnkiBackend) throws {
    let ankiDir = AccountStore.profileDirectory(for: profileID)
    try FileManager.default.createDirectory(at: ankiDir, withIntermediateDirectories: true)
    let mediaPath = ankiDir.appendingPathComponent("media").path
    try FileManager.default.createDirectory(atPath: mediaPath, withIntermediateDirectories: true)
    try backend.openCollection(
        collectionPath: ankiDir.appendingPathComponent("collection.anki2").path,
        mediaFolderPath: mediaPath,
        mediaDbPath: ankiDir.appendingPathComponent("media.db").path
    )
}

/// In-app profile switch: cancels any running sync, swaps the open collection
/// on the shared backend, flips the scoping anchor (sync prefs + keychain
/// identity), resets sync state, and refreshes widgets. The root view re-ids
/// on `selectedID`, so the whole UI rebuilds against the new collection.
@MainActor
func switchProfile(to account: AmgiAccount) async {
    let store = AccountStore.shared
    guard account.id != store.selectedID else { return }
    let previous = store.current

    @Dependency(\.ankiBackend) var backend
    @Dependency(\.syncCoordinator) var syncCoordinator

    syncCoordinator.cancel()
    try? backend.closeCollection()
    store.select(account)
    do {
        try openCollection(for: account.id, backend: backend)
    } catch {
        // Roll back rather than leave the app with no open collection.
        store.select(previous)
        do {
            try openCollection(for: previous.id, backend: backend)
        } catch let rollbackError {
            // Both the switch and the rollback failed, so nothing is open.
            // Discarding this left every screen failing its fetch with no
            // explanation — the app looked empty rather than broken.
            Log.decks.error("Profile switch and rollback both failed: \(rollbackError)")
            store.switchFailure = """
                Couldn't open either profile's collection. Quit and reopen \
                Amgi. If that doesn't help, reset the collection from \
                Settings > Maintenance.
                """
        }
        return
    }
    syncCoordinator.resetForProfileSwitch()
    await writeWidgetSnapshot()
}
