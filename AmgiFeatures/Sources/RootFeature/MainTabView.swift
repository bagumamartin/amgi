import AmgiAppCore
import AnkiKit
import DecksFeature
import ReaderFeature
import SettingsFeature
import StatsFeature
import SwiftUI
import SyncFeature

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
struct MainTabView: View {
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
            Button { startSync() } label: {
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
