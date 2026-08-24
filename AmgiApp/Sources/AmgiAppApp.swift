// AmgiApp/Sources/AmgiAppApp.swift
#if os(iOS)
import BackgroundTasks
#endif
import SwiftUI
#if os(macOS)
import AppKit
#endif
import AmgiReader
import AmgiReaderDictionary
import AmgiIcons
import AmgiTheme
import AmgiUI
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
    @Environment(\.openWindow) private var openWindow
    @State private var pendingReviewDeckId: DeckID? = nil
    @AppStorage("appFont") private var appFontRaw: String = AppFont.system.rawValue
    // Mirrors MainTabView's persisted selection so menu commands can switch
    // sections.
    @Shared(.appStorage(NavigationPreferences.rootSection)) private var rootSection: String = MainSection.study.rawValue
    @Shared(.appStorage(ReaderPreferences.Keys.showTab)) private var showReaderTab: Bool = true
    #if os(macOS)
    @Shared(.reviewShortcuts) private var reviewShortcuts: [String: ReviewShortcut] = [:]
    @FocusedValue(\.reviewActions) private var reviewActions
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    private var destination: Destination {
        onboardingCompleted ? .main : .onboarding
    }

    init() {
        migrateRootSectionPreference()
        migrateDeckSortOrderPreference()

        // Deck tiles render Phosphor glyphs through this bridge; the watch
        // target never registers one and keeps letter tiles.
        DeckIconRendering.provider = { iconName in
            AmgiIcons.DeckIconGlyph.image(for: iconName)
        }

        #if DEBUG
//        if KeychainHelper.loadEndpoint() == nil {
//            try? KeychainHelper.saveEndpoint("https://sync.ankiweb.net")
//            @Shared(.syncMode) var syncMode
//            $syncMode.withLock { $0 = .custom }
//            $onboardingCompleted.withLock { $0 = true }
//        }
        #endif

        // Widget snapshot refresh via BGTaskScheduler is iOS-only: the
        // BackgroundTasks framework doesn't exist on macOS. AmgiWidget itself
        // does build for macOS (see project.yml) and shares the same App
        // Group snapshot files; macOS gets its own refresh strategy below,
        // since unlike iOS it doesn't suspend the process while unfocused.
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskID.widgetRefresh,
            using: nil
        ) { @Sendable task in
            handleWidgetRefreshTask(task)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskID.automaticSync,
            using: nil
        ) { @Sendable task in
            handleAutomaticSyncTask(task)
        }
        scheduleWidgetRefreshTask()
        scheduleAutomaticSyncTask()
        #endif

        // Multi-profile bootstrap: converge any pre-group-root data
        // (sandbox container / home Application Support) into the
        // canonical group container FIRST, then the legacy single-
        // collection layout inside it.
        CollectionLayout.migrateIntoCanonicalRoot()
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

        #if os(macOS)
        // macOS has no BGTaskScheduler, but it also doesn't suspend a running
        // app the way iOS does when it's not frontmost — the process keeps
        // running until the user quits it. A simple in-process polling loop
        // is the native-feeling equivalent of iOS's BGAppRefreshTask: it keeps
        // the desktop widget fresh (new due counts, midnight rollover, streak)
        // without requiring the app window to be active. Like iOS's
        // background tasks, this stops the instant the app is quit (⌘Q) and
        // resumes on the next launch.
        //
        // Started *after* `prepareDependencies` so the loop's task inherits
        // the opened backend (see `startMacWidgetRefreshLoop`).
        startMacWidgetRefreshLoop()
        observeHelperMutations()
        MCPBridgeServer.start()
        #endif
    }

    /// Consumes requests parked by App Intents while the scene was
    /// inactive (intents run in-process, but their UI handoff only makes
    /// sense once the scene is up). DeckID(0) means "no specific deck".
    @MainActor
    private func consumeIntentRouterHandoff() {
        guard let deckID = IntentRouter.shared.consumePendingReviewDeck() else { return }
        if deckID.rawValue != 0 {
            pendingReviewDeckId = deckID
        }
        $rootSection.withLock { $0 = MainSection.study.rawValue }
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
            #if os(macOS)
            // macOS HIG: sensible default + minimum window sizes instead of
            // the iOS full-screen slab.
            .frame(minWidth: 960, minHeight: 620)
            #endif
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await writeWidgetSnapshot() }
                    consumeIntentRouterHandoff()
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
            .onOpenURL { url in
                guard url.scheme == "amgi", url.host == "study" else { return }
                $rootSection.withLock { $0 = MainSection.study.rawValue }
            }
            .themedRoot()
            .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
            #if os(macOS)
            // macOS HIG: settings/editor forms render as grouped rows (the
            // default macOS form style produces a floating-label layout).
            .formStyle(.grouped)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { reviewActions?.undo() }
                    .keyboardShortcut(reviewShortcut(.undo).keyEquivalent, modifiers: reviewShortcut(.undo).modifiers)
                    .disabled(reviewActions == nil)
            }
            CommandMenu("Card") {
                Button("Edit Note") { reviewActions?.editNote() }
                    .keyboardShortcut(reviewShortcut(.editNote).keyEquivalent, modifiers: reviewShortcut(.editNote).modifiers)
                    .disabled(reviewActions == nil)
                Divider()
                Button("Look Up") { reviewActions?.lookup() }
                    .keyboardShortcut(reviewShortcut(.lookup).keyEquivalent, modifiers: reviewShortcut(.lookup).modifiers)
                    .disabled(reviewActions == nil)
                Button("Replay Audio") { reviewActions?.replayAudio() }
                    .keyboardShortcut(reviewShortcut(.replayAudio).keyEquivalent, modifiers: reviewShortcut(.replayAudio).modifiers)
                    .disabled(reviewActions == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Library") { $rootSection.withLock { $0 = MainSection.library.rawValue } }
                    .keyboardShortcut("1", modifiers: .command)
                if showReaderTab {
                    Button("Read") { $rootSection.withLock { $0 = MainSection.read.rawValue } }
                        .keyboardShortcut("2", modifiers: .command)
                }
                Button("Study") { $rootSection.withLock { $0 = MainSection.study.rawValue } }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Stats") { $rootSection.withLock { $0 = MainSection.stats.rawValue } }
                    .keyboardShortcut("4", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Sync Now") {
                    // ContentView presents the sync sheet, which performs
                    // the endpoint/credential preflight and can show Login.
                    NotificationCenter.default.post(name: .amgiPresentSync, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(macOS)
        // macOS HIG: settings live in their own preferences window (⌘,)
        // reached from the app menu, with a source-list sidebar of panes —
        // not a tab inside the main window. See `SettingsWindowHost`.
        Window("Settings", id: "settings") {
            SettingsWindowHost()
                .frame(minWidth: 640, minHeight: 440)
                .themedRoot()
                .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
                .formStyle(.grouped)
        }
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        #endif

        #if os(macOS)
        // macOS HIG: study opens in its own resizable window (Anki Desktop
        // pattern) rather than covering the main window — the sidebar stays
        // reachable and review is a normal macOS document-like window with
        // standard close (⌘W / traffic light / Escape). `WindowGroup` (not
        // `Window`) lets the user open several review windows at once, one
        // per deck. This SDK's scene initializers carry no value, so each
        // window claims its deck from `ReviewWindowQueue` on appear.
        WindowGroup("Study", id: "review") {
            ReviewWindowHost()
                .frame(minWidth: 640, minHeight: 480)
                .themedRoot()
                .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
                .formStyle(.grouped)
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}

private extension AnkiAppApp {
    func migrateRootSectionPreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NavigationPreferences.rootSection) == nil,
              let legacyValue = defaults.string(forKey: NavigationPreferences.legacyRootSection)
        else { return }

        $rootSection.withLock { $0 = legacyValue }
    }

    func migrateDeckSortOrderPreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NavigationPreferences.deckSortOrder) == nil,
              let legacyValue = defaults.string(forKey: NavigationPreferences.legacyDeckSortOrder)
        else { return }

        defaults.set(legacyValue, forKey: NavigationPreferences.deckSortOrder)
        defaults.removeObject(forKey: NavigationPreferences.legacyDeckSortOrder)
    }

    #if os(macOS)
    func reviewShortcut(_ action: ReviewShortcutAction) -> ReviewShortcut {
        reviewShortcuts[action.rawValue] ?? action.defaultShortcut
    }
    #endif

    enum Destination {
        case onboarding
        case main
    }

}

#if os(macOS)
/// Root content of a single review window. Each window claims its deck from
/// `ReviewWindowQueue` on appear and holds it in its own `@State`, so several
/// decks can be reviewed concurrently in separate windows.
private struct ReviewWindowHost: View {
    @State private var deckID: DeckID?

    var body: some View {
        Group {
            if let deckID {
                ReviewView(deckId: deckID) { }
            } else {
                VStack(spacing: AmgiSpacing.md) {
                    Image(systemName: "graduationcap")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No deck selected")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if deckID == nil {
                deckID = ReviewWindowQueue.shared.dequeue()
            }
        }
    }
}
#endif

#if os(iOS)
/// Background task identifiers, derived from the app's bundle identifier
/// rather than hardcoded. Keeps registration + scheduling in sync with
/// `BGTaskSchedulerPermittedIdentifiers` (which uses
/// `$(PRODUCT_BUNDLE_IDENTIFIER).<suffix>` in Info.plist) even if the bundle
/// ID changes.
private enum BackgroundTaskID {
    static let widgetRefresh = "\(bundleID).widget-refresh"
    static let automaticSync = "\(bundleID).automatic-sync"

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.amgi.app"
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable { let value: T }

private func handleWidgetRefreshTask(_ task: BGTask) {
    let box = UncheckedSendableBox(value: task)
    let work = Task {
        await writeWidgetSnapshot()
        box.value.setTaskCompleted(success: true)
        scheduleWidgetRefreshTask()
    }
    task.expirationHandler = {
        work.cancel()
        box.value.setTaskCompleted(success: false)
    }
}

private func handleAutomaticSyncTask(_ task: BGTask) {
    let box = UncheckedSendableBox(value: task)
    let work = Task { @MainActor in
        NotificationCenter.default.post(name: .amgiPerformBackgroundSync, object: nil)
        try? await Task.sleep(for: .seconds(20))
        box.value.setTaskCompleted(success: !Task.isCancelled)
        scheduleAutomaticSyncTask()
    }
    task.expirationHandler = {
        work.cancel()
        box.value.setTaskCompleted(success: false)
    }
}

/// Schedules a BGAppRefreshTask to fire shortly after the next midnight.
/// The task writes a fresh widget snapshot so the widget shows today's counts
/// even if the user hasn't opened the app yet.
private func scheduleWidgetRefreshTask() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.widgetRefresh)
    let cal = Calendar.current
    let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    // Fire 5 minutes after midnight so Anki's day rollover has settled.
    request.earliestBeginDate = cal.date(byAdding: .minute, value: 5, to: tomorrow) ?? tomorrow
    try? BGTaskScheduler.shared.submit(request)
}

private func scheduleAutomaticSyncTask() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.automaticSync)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
}
#endif

#if os(macOS)
/// Refreshes the widget snapshot every 15 minutes for as long as the app
/// process is alive, independent of window focus. Skipped under XCTest via
/// the same guard `writeWidgetSnapshot()` uses internally.
/// Observes the amgi-mcp helper's change notification. Every agent
/// mutation lands in the SAME collection.anki2 this app has open; the
/// notification just tells us to bump `CollectionStore`'s generation so
/// all generation-keyed screens reload and show the agent's edits
/// immediately. Sync propagation rides the normal automatic-sync cycle.
#if os(macOS)
private func observeHelperMutations() {
    let observer = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.amgi.collection.changed"),
        object: nil,
        queue: nil
    ) { _ in
        Task { @MainActor in
            @Dependency(\.collectionStore) var store
            store.invalidateAll(origin: .helperMutation)
        }
    }
    // Process-lifetime observer; no removal needed.
    _ = observer
}
#endif

private func startMacWidgetRefreshLoop() {
    // An inheriting `Task` (not `Task.detached`) so the loop carries the
    // dependency context set up by `prepareDependencies` — i.e. the opened
    // `AnkiBackend`. `Task.detached` would start a fresh task tree with
    // default dependencies (a fresh, unopened backend), making every
    // `writeWidgetSnapshot()` fail at runtime.
    Task(priority: .background) {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15 * 60))
            await writeWidgetSnapshot()
        }
    }
}

/// macOS single-instance guard for URL (widget-click) launches.
///
/// Clicking a widget delivers `amgi://study` through LaunchServices. When the
/// URL scheme is registered to a different copy of the app than the one
/// currently running (e.g. the Xcode-launched build in DerivedData vs. a copy
/// in /Applications), LaunchServices can start a second process. Detect that
/// here and hand off to the running instance instead of showing a duplicate
/// window. Normal launches (Run in Xcode, Dock, Finder) carry no URL and are
/// untouched.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let firstURL = urls.first, firstURL.scheme == "amgi" else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bagumamartin.AmgiApp"
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ownPID })
        else { return } // First instance — SwiftUI's onOpenURL handles the URL.
        if #available(macOS 14.0, *) {
            existing.activate(options: [.activateAllWindows])
        } else {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        NSApp.terminate(nil)
    }
}
#endif
