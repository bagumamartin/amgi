// AmgiApp/Sources/Shared/CollectionChrome.swift
package import SwiftUI
import AmgiUI
import AmgiTheme
import AnkiKit
import AnkiClients
import Dependencies
public import Foundation

// MARK: - Engine undo monitor

/// Observable mirror of the ENGINE undo stack (not UIPasteboard/undoManager):
/// `canUndo` plus human label ("Delete Notes") driving contextual trailing
/// toolbars. Refreshes on demand — callers key off CollectionStore generation
/// so every committed mutation re-arms us (same rails as everything else).
@MainActor
@Observable
final class EngineUndoMonitor {
    private(set) var canUndo = false
    private(set) var undoText = ""
    private(set) var canRedo = false

    @ObservationIgnored @Dependency(\.cardClient) private var cardClient

    func refresh() async {
        guard let status = try? await cardClient.undoStatus() else { return }
        canUndo = status.canUndo
        undoText = status.undoText
        canRedo = status.canRedo
    }

    func undoNow() async {
        try? await cardClient.undoLast()
        await refresh()
    }
}

package struct EngineUndoButton: View {
    @State private var monitor = EngineUndoMonitor()
    @Dependency(\.collectionStore) private var store

    package init() {}

    package var body: some View {
        Button {
            Task { await monitor.undoNow() }
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!monitor.canUndo)
        .accessibilityLabel(monitor.canUndo ? "Undo \(monitor.undoText)" : "Nothing to undo")
        .help(monitor.canUndo ? "Undo \(monitor.undoText)" : "Undo")
        .task(id: store.generation) { await monitor.refresh() }
    }
}

// MARK: - Sync

extension Notification.Name {
    /// Posted by `SyncToolbarButton`. Observed by `.syncFlow()` so every
    /// screen can fire the same preflight/sync sheet without importing
    /// SyncFeature (AmgiAppShared cannot).
    public static let amgiPresentSync = Notification.Name("amgiPresentSync")

    /// Fired by the iOS automatic-sync background task. Observed by the
    /// sync flow, which runs a quiet automatic sync without presenting UI.
    public static let amgiPerformBackgroundSync = Notification.Name("com.amgiapp.performBackgroundSync")
}

/// Standalone sync affordance for screens whose trailing slot carries the
/// ever-present sync glyph. Posts the app-wide `.amgiPresentSync` rail
/// consumed by `.syncFlow()`, so every concerned screen reaches the same
/// preflight/sync sheet without new plumbing.
package struct SyncToolbarButton: View {
    package init() {}

    package var body: some View {
        Button {
            NotificationCenter.default.post(name: .amgiPresentSync, object: nil)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .help("Sync")
        .accessibilityLabel("Sync")
    }
}

// MARK: - Search chrome

// Collection search lives in Browse and nowhere else. Library/Read/Study/
// Stats carry no notes-search field and no results host — the earlier
// root-level `.searchable` + in-place results swap (NotesSearchFieldModifier /
// SearchSectionView / RootSearchResultsView / RootSearchHandoff) is gone.
// Read's book filter and the in-sheet pickers are list filters, not
// collection search, and stay where they are.

extension View {
    /// iOS 26 collapses an inactive toolbar search field into the floating
    /// bottom-right button. Attach AFTER `.searchable`. Split-view Browse
    /// (iPad) uses this; the compact search tab does not — tab-bar search
    /// is a different morph, and `searchToolbarBehavior` is a no-op there.
    ///
    /// Deliberately iOS-only (`#if os(iOS)`): Mac keeps its persistent
    /// toolbar field (Mail / Anki Desktop parity). `searchToolbarBehavior`
    /// is documented for macOS 26; opting in is a one-line change later.
    @ViewBuilder
    package func searchMinimizedIfAvailable() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.searchToolbarBehavior(.minimize)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// iOS 26 shrinks the tab bar on scroll, matching Music. No-op on
    /// earlier iOS and on macOS (which does not use this `TabView`).
    @ViewBuilder
    package func tabBarMinimizedOnScrollIfAvailable() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
