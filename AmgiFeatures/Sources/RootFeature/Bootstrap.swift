import AmgiAppCore
import AmgiAppShared
import AmgiIcons
import AmgiReader
import AmgiUI
import AnkiBackend
import AnkiClients
import AnkiKit
import DecksFeature
import Dependencies
import Foundation
import SettingsFeature
import SwiftUI
import SyncFeature

/// The app's dependency bootstrap. Called once from the host's `App.init`.
public enum AmgiRoot {
    /// Set when the collection could not be opened at launch. Read by
    /// `RootView` to route to `StartupErrorView`. Decided once during
    /// `bootstrap()` and never changed afterwards.
    @MainActor private(set) static var startupError: String?

    @MainActor
    public static func bootstrap() {
        AppSignpost.measure("Bootstrap") { bootstrapBody() }
    }

    @MainActor
    private static func bootstrapBody() {
        LegacyAmgiMigration.run()
        migratePreferences()
        WidgetSnapshotStore.migrateLegacySnapshotsIfNeeded()
        // Deck tiles render Phosphor glyphs through this bridge; the watch
        // target never registers one and keeps letter tiles.
        DeckIconRendering.provider = { iconName in
            AmgiIcons.DeckIconGlyph.image(for: iconName)
        }
        DeckIconLookup.refresh = { await DeckIconOverrides.refresh() }
        DeckIconLookup.initialIcon = { deckId, name in
            DeckIconOverrides.initialIcon(deckId: deckId, name: name)
        }
        DeckIconLookup.resolvedIcon = { deckId, name, fullName in
            await DeckIconOverrides.resolvedIcon(deckId: deckId, name: name, fullName: fullName)
        }

        #if os(iOS)
        registerBackgroundTasks()
        #endif

        // Multi-profile bootstrap: converge any pre-group-root data
        // (sandbox container / home Application Support) into the
        // canonical group container FIRST, then migrate the legacy
        // single-collection layout into the default profile, then open
        // the selected profile's collection.
        CollectionLayout.migrateIntoCanonicalRoot()
        AccountStore.migrateLegacyCollectionIfNeeded()
        let activeProfile = AccountStore.shared.current

        // `try!` here turned any collection-open failure into a crash inside
        // init — on every launch, permanently, with no in-app recovery. A
        // corrupt collection.anki2, a schema written by a newer Anki, or a
        // full disk left the user with delete-and-reinstall as their only
        // option, which destroys the local collection. That state is exactly
        // what an interrupted full-download or import leaves behind.
        //
        // checkDatabase() is also gone from the launch path: it is one of the
        // longest blocking calls the engine has, and running it before the
        // first frame made cold launch scale with collection size. It remains
        // available as an explicit action in Settings > Maintenance.
        //
        // The open itself is deliberately NON-fatal: MCP helper sessions
        // legitimately hold the collection while the app is closed (rslib's
        // exclusive lock), so `openCollection` can fail on launch with
        // "already open". A `try!` here was a guaranteed launch crash; the
        // busy screen + background retry in `CollectionLaunchState` degrades
        // gracefully instead, and the helpers switch to bridged mode as soon
        // as the open succeeds.
        var openError: String?
        var launchBackend: AnkiBackend?
        do {
            let backend = try AnkiBackend(preferredLangs: AppLocale.languageTags)
            try openCollection(for: activeProfile.id, backend: backend)
            launchBackend = backend
        } catch {
            openError = error.localizedDescription
            // The backend handle itself is cheap and lock-free — only the
            // collection open contends. Rebuild it so the bridge and the
            // retry loop have something to drive.
            launchBackend = try? AnkiBackend(preferredLangs: AppLocale.languageTags)
        }

        guard let launchBackend else {
            // Both the open and the lock-free backend rebuild failed —
            // nothing exists to retry with, so this is fatal rather than
            // busy. In practice `AnkiBackend.init` never throws; this is
            // the "full disk / broken install" path.
            startupError = openError ?? "Couldn't initialize the app backend."
            return
        }

        let syncCoordinator = SyncCoordinator()
        prepareDependencies {
            $0.ankiBackend = launchBackend
            $0.syncCoordinator = syncCoordinator
            $0.collectionStore.resetForProfileSwitch(to: activeProfile.id)
            // CollectionStore is deliberately ignorant of SyncFeature. The
            // composition root injects this small activity rail instead, so
            // every confirmed local mutation gets one debounced widget
            // refresh and one debounced collection sync.
            $0.collectionStore.onCollectionChange = { origin in
                if origin != .refresh {
                    Task { await SystemSpotlightIndexer.shared.scheduleDeckRefresh() }
                }
                let reason: String
                switch origin {
                case .localUser:
                    reason = "Local collection change"
                case .helperMutation:
                    reason = "Agent (MCP) collection change"
                case .remoteSync:
                    // SyncCoordinator owns the post-sync widget write; this
                    // invalidation is only for the shared UI cache.
                    return
                case .refresh:
                    return
                }
                WidgetRefreshCoordinator.shared.request(reason: reason)
                if origin == .localUser || origin == .helperMutation {
                    syncCoordinator.requestAutomaticSync(reason: reason)
                }
            }
            // Wire the Anki-backed concrete realization of the dictionary
            // engine's abstract config store. Keeps the engine package
            // (AmgiReaderDictionary) free of Anki imports.
            $0.dictionaryConfigStore = AnkiBackedDictionaryConfigStore.makeStore()
        }

        CollectionLaunchState.shared.configure(
            backend: launchBackend,
            profileID: activeProfile.id,
            error: openError
        )
        if openError == nil {
            Task { await SystemSpotlightIndexer.shared.scheduleDeckRefresh() }
        }

        #if os(macOS)
        // Started *after* `prepareDependencies` so the loop's task inherits
        // the opened backend (see `startMacWidgetRefreshLoop`).
        startMacWidgetRefreshLoop()
        observeHelperMutations()
        MCPBridgeServer.start()
        #endif
    }

    /// One-time migrations of pre-rename preference keys. Dotted keys break
    /// `@Shared`'s key-value observation, so the values are carried over and
    /// the legacy keys removed.
    private static func migratePreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: NavigationPreferences.rootSection) == nil,
           let legacyValue = defaults.string(forKey: NavigationPreferences.legacyRootSection) {
            defaults.set(legacyValue, forKey: NavigationPreferences.rootSection)
        }
        if defaults.object(forKey: NavigationPreferences.deckSortOrder) == nil,
           let legacyValue = defaults.string(forKey: NavigationPreferences.legacyDeckSortOrder) {
            defaults.set(legacyValue, forKey: NavigationPreferences.deckSortOrder)
            defaults.removeObject(forKey: NavigationPreferences.legacyDeckSortOrder)
        }
    }
}
