// AmgiApp/Sources/ContentView.swift
import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AnkiKit
import Sharing
import Dependencies
import SyncFeature
import ReviewFeature
import ReaderFeature
import StatsFeature
import DecksFeature
import SettingsFeature

/// App root. Hosts the tab bar (`MainTabView`) and orchestrates the
/// cross-cutting flows that sit above it: sync, deck import, and the review
/// cover. Each flow is a single modifier owned by the feature it belongs to,
/// so the body stays a thin composition.
struct ContentView: View {
    @Binding var pendingReviewDeckId: DeckID?

    @Dependency(\.collectionStore) private var store

    @State private var showImport = false
    @State private var refreshID = UUID()

    @Shared(.appStorage(ReaderPreferences.Keys.showTab))
    private var showReaderTab: Bool = true

    var body: some View {
        MainTabView(
            refreshID: refreshID,
            showReaderTab: showReaderTab,
            onImport: { showImport = true },
            onSelectStudyDeck: { pendingReviewDeckId = $0 }
        )
        .alert(
            "Couldn't switch profile",
            isPresented: Binding(
                get: { AccountStore.shared.switchFailure != nil },
                set: { if !$0 { AccountStore.shared.switchFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { AccountStore.shared.switchFailure = nil }
        } message: {
            Text(AccountStore.shared.switchFailure ?? "")
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
    }
}

/// Root tab bar. Pure layout: each tab wraps a feature view in a
/// `NavigationStack`. `refreshID` (bumped by the host after sync / import /
/// review) now only drives the tabs not yet on `CollectionStore` — Library
/// and Study reload via the store's generation instead. All side effects are
/// forwarded to the host via closures or `\.startSync` so this view owns no
/// I/O or sync state.
///
/// `refreshID` is *handed to* the two tabs that reload from it, not applied as
/// an `.id()`. As an `.id()` it discarded each tab's whole subtree — scroll
/// position, search text, selected deck, pushed navigation — to trigger a
/// reload their own `.task` already performs. Settings took the teardown and
/// got nothing for it: its root has no data load at all.
private struct MainTabView: View {
    let refreshID: UUID
    let showReaderTab: Bool
    let onImport: () -> Void
    let onSelectStudyDeck: (DeckID) -> Void

    @Environment(\.startSync) private var startSync

    var body: some View {
        TabView {
            // 1. Library
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack {
                    DeckListView(onSwitchProfile: { await switchProfile(to: $0) })
                        .toolbar { libraryToolbar }
                }
            }
            // 2. Reader
            if showReaderTab {
                Tab("Read", systemImage: "book") {
                    NavigationStack {
                        ReaderLibraryView(refreshID: refreshID)
                    }
                }
            }
            // 3. Study
            Tab("Study", systemImage: "graduationcap") {
                NavigationStack {
                    StudyLandingView(onSelectDeck: onSelectStudyDeck)
                }
            }
            // 4. Stats
            Tab("Stats", systemImage: "chart.bar") {
                NavigationStack {
                    StatsDashboardView(refreshID: refreshID)
                }
            }
            // 5. Settings
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView(onSwitchProfile: { await switchProfile(to: $0) })
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: startSync) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .accessibilityLabel("Sync")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onImport) {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import deck")
        }
    }
}
