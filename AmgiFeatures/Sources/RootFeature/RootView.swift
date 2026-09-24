public import SwiftUI
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AnkiKit
import AnkiBackend
import AppIntents
import AppIntentsFeature
import AssistantFeature
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
/// screen; the cross-cutting flows above the tabs (sync, the
/// review cover); and the root chrome (`.themedRoot()`, the app font, the
/// profile re-id, the deep link, the scene-phase widget refresh).
public struct RootView: View {
    public init() {}

    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Environment(\.scenePhase) private var scenePhase
    @Shared(.appStorage(AppearancePreferences.Keys.appFont))
    private var appFontRaw: String = AppFont.system.rawValue

    @Dependency(\.collectionStore) private var store
    @Dependency(\.ankiBackend) private var backend
    @Dependency(\.syncCoordinator) private var syncCoordinator
    @Bindable private var accountStore = AccountStore.shared

    @State private var pendingReviewDeckId: DeckID?
    @State private var pullCooling = false
    @State private var refreshID = UUID()
    @State private var studyTodayRequest = 0
    @State private var studyTodayDeckID: Int64?
    @State private var launchState = CollectionLaunchState.shared
    @State private var importRequestRouter = ImportRequestRouter.shared
    @State private var pendingImport: ImportRequest?
    @State private var exportRequestRouter = ExportRequestRouter.shared
    @State private var pendingExport: ExportRequest?
    @State private var appNavigation = AppNavigationCoordinator.shared
    @State private var assistantSheet: AssistantSheetRequest?

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
            .id(accountStore.selectedContext.selectionID)
            .onChange(of: accountStore.selectedID) {
                pendingReviewDeckId = nil
                pendingImport = nil
                pendingExport = nil
                studyTodayDeckID = nil
                studyTodayRequest = 0
                assistantSheet = nil
                BrowseLauncher.shared.discardPending()
                exportRequestRouter.discardPending()
                appNavigation.discardPending()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await WidgetRefreshCoordinator.shared.refreshNow()
                        syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "App became active")
                        syncCoordinator.runScheduledCollectionSyncIfNeeded()
                    }
                    presentNavigationRequestIfPossible()
                } else if newPhase == .background {
                    Task {
                        await WidgetRefreshCoordinator.shared.refreshNow()
                        syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "App entered background")
                    }
                }
            }
            .onChange(of: appNavigation.requestID) {
                presentNavigationRequestIfPossible()
            }
            .onChange(of: assistantSheet?.id) {
                presentNavigationRequestIfPossible()
            }
            .onChange(of: launchState.openError) {
                presentNavigationRequestIfPossible()
            }
            .onOpenURL { url in
                if url.isFileURL {
                    importRequestRouter.request(url)
                    return
                }
                guard url.scheme == "amgi" else { return }
                switch url.host {
                case "study":
                    // `amgi://study` is the widget route. Increment before
                    // switching so an already-mounted Study tab receives a
                    // fresh request and returns from any historical period.
                    // A configured widget may also carry its deck ID; 0 means
                    // the collection-wide Today desk. New widget files carry
                    // their profile; legacy deck-specific files are rejected
                    // rather than allowed to target a same-numbered deck in
                    // the current profile.
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let requestedDeckID = components?.queryItems?
                        .first(where: { $0.name == "deckId" })?
                        .value
                        .flatMap { Int64($0) }
                    let requestedProfileID = components?.queryItems?
                        .first(where: { $0.name == "profileID" })?
                        .value
                    let currentProfileID = AccountStore.shared.selectedContext.id
                    if let requestedProfileID, requestedProfileID != currentProfileID {
                        return
                    }
                    if requestedDeckID != nil, requestedProfileID == nil {
                        return
                    }
                    studyTodayDeckID = requestedDeckID == 0 ? nil : requestedDeckID
                    studyTodayRequest &+= 1
                    $sectionRaw.withLock { $0 = MainSection.study.rawValue }
                case "browse":
                    // amgi://browse?deck=<name> drill-ins; URLComponents
                    // restores percent-encoding and DeckSearch escapes the
                    // Anki query metacharacters.
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let value = components.queryItems?.first(where: { $0.name == "deck" })?.value,
                       !value.isEmpty {
                        let requestedProfileID = components.queryItems?
                            .first(where: { $0.name == "profileID" })?.value
                        guard requestedProfileID == AccountStore.shared.selectedContext.id else { return }
                        BrowseLauncher.shared.launch(query: DeckSearch.term(value))
                    } else {
                        BrowseLauncher.shared.launch()
                    }
                    $sectionRaw.withLock { $0 = MainSection.browse.rawValue }
                case "review":
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    guard let deckIdStr = components?.queryItems?
                        .first(where: { $0.name == "deckId" })?.value,
                        let deckId = Int64(deckIdStr)
                    else { return }
                    let requestedProfileID = components?.queryItems?
                        .first(where: { $0.name == "profileID" })?.value
                    if let requestedProfileID,
                       requestedProfileID != AccountStore.shared.selectedContext.id {
                        return
                    }
                    if requestedProfileID == nil { return }
                    pendingReviewDeckId = DeckID(deckId)
                    $sectionRaw.withLock { $0 = MainSection.study.rawValue }
                default:
                    break
                }
            }
            // Idle-time WebView prewarm: after launch settles, spawn WebKit's
            // card-rendering processes so the first HTML review card never
            // waits on a cold-start (logs: 1.8–3.7s). DeckDetailView re-checks
            // on every appearance for users who get there faster.
            .task {
                // The scene-phase hook is not guaranteed to see an initial
                // active transition, so publish one startup snapshot as well.
                await WidgetRefreshCoordinator.shared.refreshNow()
                syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "App launched")
                syncCoordinator.runScheduledCollectionSyncIfNeeded()
                presentNavigationRequestIfPossible()
                try? await Task.sleep(for: .seconds(2))
                CardWebViewPrewarmer.shared.prewarmIfNeeded()
            }
            .themedRoot()
            .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
    }

    /// Consumes the oldest durable system-navigation request. Requests remain
    /// parked while onboarding is active or the collection is temporarily
    /// unavailable, and the coordinator itself rejects stale profile contexts.
    private func presentNavigationRequestIfPossible() {
        guard launchState.openError == nil,
              AmgiRoot.startupError == nil,
              onboardingCompleted,
              pendingImport == nil,
              pendingExport == nil,
              pendingReviewDeckId == nil,
              assistantSheet == nil
        else { return }

        guard let request = appNavigation.consume() else { return }
        switch request.route {
        case .review(let deckID):
            pendingReviewDeckId = DeckID(deckID)
            $sectionRaw.withLock { $0 = MainSection.study.rawValue }
        case .browse(let query):
            BrowseLauncher.shared.launch(query: query)
            $sectionRaw.withLock { $0 = MainSection.browse.rawValue }
        case .browseDeck(let deckID):
            BrowseLauncher.shared.launch(deckID: deckID)
            $sectionRaw.withLock { $0 = MainSection.browse.rawValue }
        case .openNote(let noteID):
            BrowseLauncher.shared.launch(query: "nid:\(noteID)")
            $sectionRaw.withLock { $0 = MainSection.browse.rawValue }
        case .studyAssistant(let prompt):
            assistantSheet = AssistantSheetRequest(prompt: prompt)
        case .presentSync:
            NotificationCenter.default.post(name: .amgiPresentSync, object: nil)
        }
    }

    private func presentPendingImportIfPossible() {
        guard launchState.openError == nil, AmgiRoot.startupError == nil else { return }
        guard pendingImport == nil, pendingReviewDeckId == nil, pendingExport == nil, assistantSheet == nil else { return }
        guard let request = importRequestRouter.consume() else { return }
        pendingImport = request
    }

    private func presentPendingExportIfPossible() {
        guard launchState.openError == nil, AmgiRoot.startupError == nil else { return }
        // Imports and exports are both root-owned. Keep a request parked while
        // another modal is visible instead of allowing two file coordinators
        // to race for the collection lifecycle.
        guard pendingImport == nil, pendingReviewDeckId == nil, pendingExport == nil, assistantSheet == nil else { return }
        guard let request = exportRequestRouter.consume() else { return }
        pendingExport = request
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
            studyTodayRequest: studyTodayRequest,
            studyTodayDeckID: studyTodayDeckID,
            onSelectStudyDeck: {
                pullCooling = false
                pendingReviewDeckId = $0
            },
            onPullCooling: {
                pullCooling = true
                pendingReviewDeckId = DeckID(0)
            },
            onOpenAssistant: {
                assistantSheet = AssistantSheetRequest(prompt: nil)
            }
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
        .onChange(of: importRequestRouter.requestID) {
            presentPendingImportIfPossible()
        }
        .onChange(of: exportRequestRouter.requestID) {
            presentPendingExportIfPossible()
        }
        .task {
            // A file delivered while onboarding or a locked collection is
            // showing stays parked in ImportRequestRouter until the app can
            // safely inspect and import it. Export requests use the same rule.
            presentPendingImportIfPossible()
            presentPendingExportIfPossible()
        }
        .sheet(item: $pendingImport, onDismiss: {
            presentPendingImportIfPossible()
            presentPendingExportIfPossible()
            presentNavigationRequestIfPossible()
        }) { request in
            ImportReviewView(
                sourceURL: request.url,
                replaceCollection: replaceCurrentCollection,
                onComplete: {
                    store.invalidateAll(origin: .localUser)
                    refreshID = UUID()
                }
            )
        }
        .sheet(item: $pendingExport, onDismiss: {
            presentPendingImportIfPossible()
            presentPendingExportIfPossible()
            presentNavigationRequestIfPossible()
        }) { request in
            ExportReviewView(
                request: request,
                beforeExport: {
                    guard syncCoordinator.beginCollectionLifecycle() else {
                        throw CancellationError()
                    }
                    await syncCoordinator.cancelAndWait()
                    await WidgetRefreshCoordinator.shared.cancelAndWait()
                },
                afterExport: {
                    syncCoordinator.endCollectionLifecycle()
                },
                onCollectionFailure: { message, profileID in
                    guard AccountStore.shared.selectedID == profileID else { return }
                    CollectionLaunchState.shared.configure(
                        backend: backend,
                        profileID: profileID,
                        error: message
                    )
                    pendingExport = nil
                },
                onComplete: {
                    store.invalidateAll()
                    refreshID = UUID()
                }
            )
        }
        .sheet(item: $assistantSheet, onDismiss: {
            presentNavigationRequestIfPossible()
        }) { request in
            StudyAssistantView(initialPrompt: request.prompt) { citation in
                guard let profile = citation.profile,
                      profile.isCurrent(AccountStore.shared.selectedContext)
                else { return }
                appNavigation.submit(.openNote(noteID: citation.id), profile: profile)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .fullScreenCover(item: $pendingReviewDeckId) { deckId in
            let profile = AccountStore.shared.selectedContext
            let deckEntity = DeckEntity(
                context: profile,
                deckID: deckId,
                name: deckId.rawValue == 0 ? "All Decks" : "Review Deck"
            )
            return ReviewView(deckId: deckId, pullCooling: pullCooling) {
                pendingReviewDeckId = nil
                pullCooling = false
                store.invalidateAll(origin: .localUser)
                refreshID = UUID()
                presentPendingImportIfPossible()
                presentPendingExportIfPossible()
                presentNavigationRequestIfPossible()
            }
            .appEntityIdentifierIfAvailable(deckEntity.map { EntityIdentifier(for: $0) })
        }
        // Review presents the reader's dictionary popup without importing
        // ReaderFeature; the root injects it. Applied last so it reaches the
        // tabs and every sheet/cover presented above.
        .environment(\.lookupPopup, ReaderLookupPopup())
        .environment(\.accountMenuProvider, RootAccountMenu())
    }
}

private struct AssistantSheetRequest: Identifiable {
    let id = UUID()
    let prompt: String?
}
