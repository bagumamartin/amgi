public import SwiftUI
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AnkiKit
import Dependencies
import Foundation
import ReaderFeature
import ReviewFeature
import SettingsFeature
import Sharing
import SyncFeature

/// The app's whole view composition. The host target supplies only `@main`.
///
/// Owns the routing between onboarding, the tab bar, and the startup-error
/// screen; the cross-cutting flows above the tabs (sync, deck import, the
/// review cover); and the root chrome (`.themedRoot()`, the app font, the
/// profile re-id, the deep link, the scene-phase widget refresh).
public struct RootView: View {
    public init() {}

    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Environment(\.scenePhase) private var scenePhase
    @Shared(.appStorage(AppearancePreferences.Keys.appFont))
    private var appFontRaw: String = AppFont.system.rawValue

    @Dependency(\.collectionStore) private var store
    @Bindable private var accountStore = AccountStore.shared

    @State private var pendingReviewDeckId: DeckID?
    @State private var showImport = false
    @State private var refreshID = UUID()
    @State private var launchState = CollectionLaunchState.shared

    /// Mirrors MainTabView's persisted selection so URL handlers, intents,
    /// and menu commands can switch sections through one source of truth.
    @Shared(.appStorage(NavigationPreferences.rootSection)) private var sectionRaw: String = MainSection.study.rawValue

    @Shared(.appStorage(ReaderPreferences.Keys.showTab))
    private var showReaderTab: Bool = true

    public var body: some View {
        routed
            // Rebuild the entire view tree when the active profile changes —
            // every screen holds state derived from the previously open
            // collection. `.id(_:)` sets identity for `routed` and its
            // subtree only; it does not touch state held on `RootView`
            // itself, so `pendingReviewDeckId` needs the explicit clear
            // below.
            .id(accountStore.selectedID)
            .onChange(of: accountStore.selectedID) { pendingReviewDeckId = nil }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await writeWidgetSnapshot() }
                    consumeIntentRouterHandoff()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "amgi" else { return }
                switch url.host {
                case "study":
                    $sectionRaw.withLock { $0 = MainSection.study.rawValue }
                case "browse":
                    // amgi://browse?deck=<name> drill-ins; %20 etc. restored
                    // by URLComponents so quoted deck names survive.
                    var query: String?
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let value = components.queryItems?.first(where: { $0.name == "deck" })?.value,
                       !value.isEmpty {
                        query = "deck:\"\(value)\""
                    }
                    BrowseLauncher.shared.launch(query: query)
                    $sectionRaw.withLock { $0 = MainSection.browse.rawValue }
                case "review":
                    guard let deckIdStr = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "deckId" })?.value,
                        let deckId = Int64(deckIdStr)
                    else { return }
                    pendingReviewDeckId = DeckID(deckId)
                default:
                    break
                }
            }
            // Idle-time WebView prewarm: after launch settles, spawn WebKit's
            // card-rendering processes so the first HTML review card never
            // waits on a cold-start (logs: 1.8–3.7s). DeckDetailView re-checks
            // on every appearance for users who get there faster.
            .task {
                try? await Task.sleep(for: .seconds(2))
                CardWebViewPrewarmer.shared.prewarmIfNeeded()
            }
            .themedRoot()
            .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
    }

    /// Consumes requests parked by App Intents while the scene was
    /// inactive (intents run in-process, but their UI handoff only makes
    /// sense once the scene is up). DeckID(0) means "no specific deck".
    private func consumeIntentRouterHandoff() {
        guard let deckID = IntentRouter.shared.consumePendingReviewDeck() else { return }
        if deckID.rawValue != 0 {
            pendingReviewDeckId = deckID
        }
        $sectionRaw.withLock { $0 = MainSection.study.rawValue }
    }

    @ViewBuilder
    private var routed: some View {
        if launchState.openError != nil {
            // The collection is held by an MCP helper session — retry in
            // the background and show the busy screen until it opens.
            CollectionBusyView()
        } else if let startupError = AmgiRoot.startupError {
            StartupErrorView(message: startupError)
        } else if onboardingCompleted {
            main
        } else {
            OnboardingView()
        }
    }

    private var main: some View {
        MainTabView(
            refreshID: refreshID,
            showReaderTab: showReaderTab,
            onImport: { showImport = true },
            onSelectStudyDeck: { pendingReviewDeckId = $0 }
        )
        .alert(
            "Couldn't switch profile",
            isPresented: $accountStore.hasSwitchFailure
        ) {
            Button("OK", role: .cancel) { accountStore.switchFailure = nil }
        } message: {
            Text(accountStore.switchFailure ?? "")
        }
        // still drives the tabs not yet on CollectionStore
        .syncFlow { refreshID = UUID() }
        .deckImport(isPresented: $showImport) {
            store.invalidateAll()
            refreshID = UUID()
        }
        .fullScreenCover(item: $pendingReviewDeckId) { deckId in
            ReviewView(deckId: deckId) {
                pendingReviewDeckId = nil
                store.invalidateAll()
                refreshID = UUID()
            }
        }
        // Review presents the reader's dictionary popup without importing
        // ReaderFeature; the root injects it. Applied last so it reaches the
        // tabs and every sheet/cover presented above.
        .environment(\.lookupPopup, ReaderLookupPopup())
        .environment(\.accountMenuProvider, RootAccountMenu())
    }
}
