// AmgiApp/Sources/Shared/CollectionChrome.swift
import SwiftUI
import AmgiTheme
import AnkiKit
import AnkiClients
import Dependencies

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

/// Reusable engine-undo glyph (chrome cluster + any bespoke placement).
struct EngineUndoButton: View {
    @State private var monitor = EngineUndoMonitor()
    @Dependency(\.collectionStore) private var store

    var body: some View {
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

/// Standalone sync affordance for screens whose trailing slot carries only
/// the ever-present sync (Read, Stats). Posts the app-wide `.amgiPresentSync`
/// rail consumed by ContentView, so every concerned screen reaches the same
/// preflight/sync sheet without new plumbing.
struct SyncToolbarButton: View {
    var body: some View {
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
    /// bottom-right button. Attach AFTER `.searchable`.
    ///
    /// Deliberately iOS-only (`#if os(iOS)`): the API annotation is
    /// unavailable on macOS even though the doc page lists it — and Mac
    /// SHOULD keep its persistent toolbar field anyway (HIG), which the
    /// plain-else branch guarantees.
    @ViewBuilder
    func searchMinimizedIfAvailable() -> some View {
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
}
