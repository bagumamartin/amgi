// AmgiApp/Sources/AmgiAppApp.swift
import SwiftUI
import AmgiReader
import AmgiReaderDictionary
import AmgiTheme
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
        // layout into the default profile, then resolve the active
        // profile (consuming a pending switch from the previous session
        // if one was queued in Settings → Profiles).
        AccountStore.migrateLegacyCollectionIfNeeded()
        let activeProfile = MainActor.assumeIsolated {
            AccountStore.shared.consumePendingSwitch()
        }

        try! prepareDependencies {
            let backend = try AnkiBackend(preferredLangs: ["en"])

            let ankiDir = AccountStore.profileDirectory(for: activeProfile.id)
            try FileManager.default.createDirectory(at: ankiDir, withIntermediateDirectories: true)

            let collectionPath = ankiDir.appendingPathComponent("collection.anki2").path
            let mediaPath = ankiDir.appendingPathComponent("media").path
            let mediaDbPath = ankiDir.appendingPathComponent("media.db").path
            try FileManager.default.createDirectory(
                atPath: mediaPath, withIntermediateDirectories: true
            )

            try backend.openCollection(
                collectionPath: collectionPath,
                mediaFolderPath: mediaPath,
                mediaDbPath: mediaDbPath
            )
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
