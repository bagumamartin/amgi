// AmgiApp/Sources/AmgiAppApp.swift
import SwiftUI
import AmgiReader
import AmgiReaderDictionary
import AmgiTheme
import AmgiAppCore
import AnkiBackend
import AnkiKit
import AnkiSync
import Dependencies
import Foundation
import Sharing

@main
struct AnkiAppApp: App {
    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingReviewDeckId: DeckID? = nil
    @AppStorage("appFont") private var appFontRaw: String = AppFont.system.rawValue

    private var destination: Destination {
        onboardingCompleted ? .main : .onboarding
    }

    init() {
        #if DEBUG
//        if KeychainHelper.loadEndpoint() == nil {
//            try? KeychainHelper.saveEndpoint("https://sync.ankiweb.net")
//            @Shared(.syncMode) var syncMode
//            $syncMode.withLock { $0 = .custom }
//            $onboardingCompleted.withLock { $0 = true }
//        }
        #endif

        // Multi-profile bootstrap: migrate legacy single-collection
        // layout into the default profile, then open the selected
        // profile's collection.
        AccountStore.migrateLegacyCollectionIfNeeded()
        let activeProfile = MainActor.assumeIsolated {
            AccountStore.shared.current
        }

        try! prepareDependencies {
            let backend = try AnkiBackend(preferredLangs: ["en"])
            try openCollection(for: activeProfile.id, backend: backend)
            try? backend.checkDatabase()
            $0.ankiBackend = backend
            $0.syncCoordinator = SyncCoordinator()
            // Wire the Anki-backed concrete realization of the dictionary
            // engine's abstract config store. Keeps the engine package
            // (AmgiReaderDictionary) free of Anki imports.
            $0.dictionaryConfigStore = AnkiBackedDictionaryConfigStore.makeStore()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch destination {
                case .onboarding:
                    OnboardingView()
                case .main:
                    ContentView(pendingReviewDeckId: $pendingReviewDeckId)
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
        try? backend.checkDatabase()
    } catch {
        // Roll back rather than leave the app with no open collection.
        store.select(previous)
        try? openCollection(for: previous.id, backend: backend)
        return
    }
    syncCoordinator.resetForProfileSwitch()
    await writeWidgetSnapshot()
}
