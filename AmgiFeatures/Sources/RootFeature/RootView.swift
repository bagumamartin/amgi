public import SwiftUI
import UniformTypeIdentifiers
import AmgiEmbeddings
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AmgiReviewCore
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
    @Environment(\.openWindow) private var openWindow
    @Shared(.appStorage(AppearancePreferences.Keys.appFont))
    private var appFontRaw: String = AppFont.system.rawValue

    @Dependency(\.collectionStore) private var store
    @Dependency(\.ankiBackend) private var backend
    @Dependency(\.syncCoordinator) private var syncCoordinator
    @Bindable private var accountStore = AccountStore.shared
    /// The app language. Observed so the root re-renders — and re-applies
    /// `.environment(\.locale,)` — when the user picks one in Settings.
    @Bindable private var appLocale = AppLocaleModel.shared

    @State private var pendingReviewDeckId: DeckID?
    @State private var pullCooling = false
    @State private var refreshID = UUID()
    @State private var studyTodayRequest = 0
    @State private var studyTodayDeckID: Int64?
    /// A deck the Library should open, from a deck-scoped widget. Cleared
    /// by the Library once it has pushed the deck.
    @State private var libraryDeckRequest: Int64?
    @State private var launchState = CollectionLaunchState.shared
    @State private var importRequestRouter = ImportRequestRouter.shared
    @State private var pendingImport: ImportRequest?
    @State private var readerImportRouter = ReaderImportRequestRouter.shared
    @State private var exportRequestRouter = ExportRequestRouter.shared
    @State private var pendingExport: ExportRequest?
    @State private var appNavigation = AppNavigationCoordinator.shared
    @State private var assistantSheet: AssistantSheetRequest?
    @State private var sceneActions = RootSceneActions()
    @State private var syncRequest = 0
    @State private var isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    @State private var isImportPresented = false
    @State private var sceneID = UUID()

    /// Mirrors MainTabView's persisted selection so URL handlers, intents,
    /// and menu commands can switch sections through one source of truth.
    /// The same store `MainTabView` selects tabs from. This was
    /// `@SceneStorage` under the same key — a different store — so every
    /// deep link (widget, Browse, Review, file open) wrote a tab the tab
    /// bar never read.
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
                libraryDeckRequest = nil
                assistantSheet = nil
                BrowseLauncher.shared.discardPending()
                readerImportRouter.discardPending()
                exportRequestRouter.discardPending()
                appNavigation.discardPending()
            }
            .task(id: store.generation) { CollectionRetrievalCoordinator.shared.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .amgiModelAssetChanged)) { _ in CollectionRetrievalCoordinator.shared.refresh() }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
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
            .onAppear {
                if isUITesting {
                    $showReaderTab.withLock { $0 = true }
                    $sectionRaw.withLock { $0 = MainSection.study.rawValue }
                }
                sceneActions.selectSection = { section in
                    $sectionRaw.withLock { $0 = section.rawValue }
                }
                sceneActions.presentSync = {
                    syncRequest &+= 1
                }
                sceneActions.presentImport = {
                    isImportPresented = true
                }
                sceneActions.presentExport = {
                    exportRequestRouter.request(
                        scope: .collection,
                        allowsScopeChange: true,
                        sourceName: AccountStore.shared.current.displayName
                    )
                }
                sceneActions.presentStudyAssistant = {
                    assistantSheet = AssistantSheetRequest(prompt: "")
                }
                sceneActions.isReaderEnabled = showReaderTab
            }
            .onChange(of: showReaderTab) { _, enabled in
                sceneActions.isReaderEnabled = enabled
            }
            .onDisappear {
                sceneActions.invalidate()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            // Browse's "Open in Book" hands the passage to the reader; the
            // root only brings the Read tab forward.
            .onChange(of: ReaderOpenRequestRouter.shared.pending?.id) { _, id in
                guard id != nil else { return }
                $showReaderTab.withLock { $0 = true }
                $sectionRaw.withLock { $0 = MainSection.read.rawValue }
            }
            #if os(macOS)
            .onReceive(
                DistributedNotificationCenter.default().publisher(
                    for: Notification.Name("com.ijuka.app.forwarded-url")
                )
            ) { notification in
                guard let value = notification.userInfo?["url"] as? String,
                      let url = URL(string: value),
                      ForwardedURLClaim.shared.claim(for: sceneID)
                else { return }
                handleIncomingURL(url)
                ForwardedURLClaim.shared.release(sceneID)
            }
            #endif
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
            // The one place the app's locale becomes the SwiftUI locale, so
            // `Text("…")` resolution, date and number formatting, and `L10n`
            // all agree. Engine strings (undo names, errors) are resolved once
            // in `Bootstrap` and need a relaunch to follow.
            //
            // Read through the observable store, not `AppLocale.current`:
            // `AppLocale` is a static namespace and SwiftUI will not re-run
            // this body when a `UserDefaults` key changes, so the picker would
            // write the override and nothing would re-render. See
            // `AppLocaleModel`.
            .environment(\.locale, appLocale.locale)
            .focusedSceneValue(\.rootSceneActions, sceneActions)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            handleSceneBecameActive()
        case .background:
            handleSceneEnteredBackground()
        default:
            break
        }
    }

    private func handleSceneBecameActive() {
        presentNavigationRequestIfPossible()
        Task {
            await WidgetRefreshCoordinator.shared.refreshNow()
            syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "App became active")
            syncCoordinator.runScheduledCollectionSyncIfNeeded()
        }
    }

    private func handleSceneEnteredBackground() {
        Task {
            await WidgetRefreshCoordinator.shared.refreshNow()
            syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "App entered background")
        }
    }

    private func presentReview(deckId: DeckID, pullCooling: Bool = false) {
        #if os(macOS)
        ReviewWindowQueue.shared.enqueue(deckId, pullCooling: pullCooling)
        openWindow(id: "review")
        #else
        self.pullCooling = pullCooling
        pendingReviewDeckId = deckId
        #endif
    }

    /// Whether a dropped or picked file belongs to the reader rather than to
    /// the Anki importer.
    ///
    /// Decided by extension, which is the only thing available at this point:
    /// the file may be outside any sandbox and is not read until the library
    /// actually imports it. An unrecognised extension goes to the Anki importer
    /// as before, so nothing that used to work stops working.
    private static func isReaderDocument(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "epub", "pdf": true
        default: false
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            if Self.isReaderDocument(url) {
                readerImportRouter.request(
                    url,
                    profileID: AccountStore.shared.selectedID
                )
                $showReaderTab.withLock { $0 = true }
                $sectionRaw.withLock { $0 = MainSection.read.rawValue }
            } else {
                importRequestRouter.request(url)
            }
            return
        }
        guard url.scheme == "amgi" else { return }
        switch url.host {
        case "study":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let requestedDeckID = components?.queryItems?
                .first(where: { $0.name == "deckId" })?
                .value
                .flatMap { Int64($0) }
            let requestedProfileID = components?.queryItems?
                .first(where: { $0.name == "profileID" })?
                .value
            let currentProfileID = AccountStore.shared.selectedContext.id
            guard requestedProfileID == nil || requestedProfileID == currentProfileID else { return }
            guard requestedDeckID == nil || requestedProfileID != nil else { return }
            // All Decks opens Study's Today desk; a deck-scoped widget
            // opens that deck in the Library.
            if let requestedDeckID, requestedDeckID != 0 {
                libraryDeckRequest = requestedDeckID
                $sectionRaw.withLock { $0 = MainSection.library.rawValue }
            } else {
                studyTodayDeckID = nil
                studyTodayRequest &+= 1
                $sectionRaw.withLock { $0 = MainSection.study.rawValue }
            }
        case "browse":
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
            guard let deckIDValue = components?.queryItems?
                .first(where: { $0.name == "deckId" })?.value,
                let deckID = Int64(deckIDValue)
            else { return }
            let requestedProfileID = components?.queryItems?
                .first(where: { $0.name == "profileID" })?.value
            guard let requestedProfileID,
                  requestedProfileID == AccountStore.shared.selectedContext.id
            else { return }
            presentReview(deckId: DeckID(deckID))
            $sectionRaw.withLock { $0 = MainSection.study.rawValue }
        default:
            break
        }
    }

    /// Consumes the oldest durable system-navigation request. Requests remain
    /// parked while onboarding is active or the collection is temporarily
    /// unavailable, and the coordinator itself rejects stale profile contexts.
    private func presentNavigationRequestIfPossible() {
        guard launchState.openError == nil,
              AmgiRoot.startupError == nil,
              onboardingCompleted || isUITesting,
              pendingImport == nil,
              pendingExport == nil,
              pendingReviewDeckId == nil,
              assistantSheet == nil
        else { return }

        guard let request = appNavigation.consume() else { return }
        switch request.route {
        case .review(let deckID):
            presentReview(deckId: DeckID(deckID))
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
            syncRequest &+= 1
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
        } else if onboardingCompleted || isUITesting {
            main
        } else {
            OnboardingView()
        }
    }

    private var main: some View {
        MainTabView(
            sceneActions: sceneActions,
            refreshID: refreshID,
            showReaderTab: showReaderTab,
            studyTodayRequest: studyTodayRequest,
            studyTodayDeckID: studyTodayDeckID,
            libraryDeckRequest: $libraryDeckRequest,
            onSelectStudyDeck: { deckID in
                pullCooling = false
                presentReview(deckId: deckID)
            },
            onPullCooling: {
                pullCooling = true
                presentReview(deckId: DeckID(0), pullCooling: true)
            },
            onOpenAssistant: { context in
                assistantSheet = AssistantSheetRequest(prompt: nil, contexts: context)
            },
            assistantIsPresented: assistantSheet != nil
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
        .syncFlow(requestID: syncRequest) { refreshID = UUID() }
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
        .fileImporter(
            isPresented: $isImportPresented,
            allowedContentTypes: AnkiImportFormat.supportedContentTypes + UTType.readerDocuments
        ) { result in
            if case .success(let url) = result {
                if Self.isReaderDocument(url) {
                    readerImportRouter.request(url, profileID: AccountStore.shared.selectedID)
                    $showReaderTab.withLock { $0 = true }
                    $sectionRaw.withLock { $0 = MainSection.read.rawValue }
                } else {
                    importRequestRouter.request(url)
                }
            }
        }
        .sheet(item: $pendingImport, onDismiss: {
            presentPendingImportIfPossible()
            presentPendingExportIfPossible()
            presentNavigationRequestIfPossible()
        }) { request in
            ImportReviewView(
                sourceURL: request.url,
                profileID: request.profileID,
                replaceCollection: { stagedURL in
                    try await replaceCurrentCollection(
                        with: stagedURL,
                        profileID: request.profileID,
                        lifecycleAlreadyHeld: true
                    )
                },
                beforeImport: {
                    guard syncCoordinator.beginCollectionLifecycle() else {
                        throw CancellationError()
                    }
                    await ReviewSessionActivity.shared.drain()
                    await syncCoordinator.cancelAndWait()
                    await WidgetRefreshCoordinator.shared.cancelAndWait()
                },
                afterImport: {
                    ReviewSessionActivity.shared.endDrain()
                    syncCoordinator.endCollectionLifecycle()
                },
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
        .modifier(AssistantPresentation(request: $assistantSheet, onDismiss: { presentNavigationRequestIfPossible() }, onRoute: handleAssistantRoute, onOpenNote: handleAssistantNote))
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
        .environment(\.assistantSceneNavigation, AssistantSceneNavigation(route: handleAssistantRoute, note: handleAssistantNote))
    }
    private func handleAssistantRoute(_ route: AssistantRoute) {
        assistantSheet = nil
        switch route {
        case .section(let section): if let selection = MainSection(rawValue: section) { sceneActions.select(selection) }
        case .settings: sceneActions.presentSettings()
        case .sync: sceneActions.sync()
        case .importFile: sceneActions.importFile()
        case .exportCollection: sceneActions.exportCollection()
        case .browse(let query): appNavigation.submit(.browse(query: query), profile: AccountStore.shared.selectedContext)
        case .review(let id): appNavigation.submit(.review(deckID: id), profile: AccountStore.shared.selectedContext)
        }
    }
    private func handleAssistantNote(_ citation: AssistantCitation) {
        guard let profile = citation.profile, profile.isCurrent(AccountStore.shared.selectedContext) else { return }
        assistantSheet = nil
        appNavigation.submit(.openNote(noteID: citation.id), profile: profile)
    }

}

private struct AssistantSheetRequest: Identifiable {
    let id = UUID()
    let prompt: String?
    let contexts: [AssistantContext]
    init(prompt: String?, contexts: [AssistantContext] = [.collection]) { self.prompt = prompt; self.contexts = contexts }
}

private struct AssistantPresentation: ViewModifier {
    @Binding var request: AssistantSheetRequest?
    let onDismiss: () -> Void
    let onRoute: @MainActor (AssistantRoute) -> Void
    let onOpenNote: (AssistantCitation) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panelSize = CGSize(width: 440, height: 640)
    @State private var resizeOrigin: CGSize?

    private var floats: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass != .compact
        #endif
    }
    private func close() {
        request = nil
        if floats { onDismiss() } // Compact sheets invoke their own onDismiss.
    }

    @ViewBuilder private func surface(_ request: AssistantSheetRequest) -> some View {
        StudyAssistantView(initialPrompt: request.prompt, contexts: request.contexts, onRoute: onRoute, onOpenNote: onOpenNote, onClose: close)
    }

    func body(content: Content) -> some View {
        Group {
            #if os(macOS)
            floating(content)
            #else
            if floats { floating(content) }
            else {
                content.sheet(item: $request, onDismiss: onDismiss) { request in
                    surface(request)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(32)
                }
            }
            #endif
        }
    }

    private func floating(_ content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                if let request {
                    let width = min(panelSize.width, max(0, geometry.size.width - 32))
                    let height = min(panelSize.height, max(0, geometry.size.height - 32))
                    surface(request)
                        .frame(width: width, height: height)
                        .clipShape(.rect(cornerRadius: 28))
                        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.13), radius: 20, x: 0, y: 8)
                        #if os(macOS)
                        .overlay(alignment: .bottomLeading) {
                            Image(systemName: "arrow.up.right.and.arrow.down.left")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        if resizeOrigin == nil { resizeOrigin = panelSize }
                                        guard let origin = resizeOrigin else { return }
                                        panelSize = CGSize(width: min(700, max(360, origin.width - value.translation.width)), height: max(380, origin.height - value.translation.height))
                                    }.onEnded { _ in resizeOrigin = nil })
                                .accessibilityLabel("Resize assistant")
                                .accessibilityAdjustableAction { direction in
                                    let delta: CGFloat = direction == .increment ? 40 : -40
                                    panelSize.width = min(700, max(360, panelSize.width + delta))
                                    panelSize.height = max(380, panelSize.height + delta)
                                }
                        }
                        #endif
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: request?.id)
    }
}
