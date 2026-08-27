// AmgiApp/Sources/Shared/CollectionChrome.swift
import SwiftUI
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

// MARK: - Contextual trailing chrome

/// The three-glyph trailing cluster from the design language (see
/// browse-redesign-spec §5.7 amendment): **Undo · Sync · ⋯** rendered as
/// plain system glyphs so iOS 26 groups them into the Liquid Glass capsule
/// automatically (and Mac/iPad get ordinary toolbar buttons).
///
/// - Library stays the documented four-glyph EXCEPTION (Sync · Import ·
///   Export · New Deck) and does not adopt this modifier.
/// - The sync glyph posts the app-wide `.amgiPresentSync` rail consumed by
///   ContentView, so every concerned screen reaches the same preflight/sync
///   sheet without new plumbing.
struct TrailingChromeModifier<MenuContent: View>: ViewModifier {
    /// false hides the undo glyph (screens without collection mutations).
    var showsUndo: Bool = true

    @ViewBuilder let menu: () -> MenuContent

    @State private var monitor = EngineUndoMonitor()
    @Dependency(\.collectionStore) private var store

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if showsUndo {
                        EngineUndoButton()
                    }
                    SyncToolbarButton()
                    Menu(content: menu, label: {
                        Image(systemName: "ellipsis")
                    })
                    .accessibilityLabel("More actions")
                }
            }
            // Every committed mutation bumps the store; re-arm afterwards.
            .task(id: store.generation) { await monitor.refresh() }
    }

    private var undoButton: some View {
        Button {
            Task { await monitor.undoNow() }
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!monitor.canUndo)
        .accessibilityLabel(monitor.canUndo ? "Undo \(monitor.undoText)" : "Nothing to undo")
        .help(monitor.canUndo ? "Undo \(monitor.undoText)" : "Undo")
    }
}

/// Standalone sync affordance for screens whose trailing slot carries only
/// the ever-present sync (Read, Stats).
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

extension View {
    /// Installs Undo · Sync · ⋯ at topBarTrailing with shared undo state.
    func trailingChrome(
        showsUndo: Bool = true,
        @ViewBuilder menu: @escaping () -> some View
    ) -> some View {
        modifier(TrailingChromeModifier(showsUndo: showsUndo, menu: menu))
    }

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

// MARK: - Root-screen search handoff

/// Debounces free-text from a root screen's native search field into a
/// live handoff to the Browse section (the moment real characters land,
/// Browse takes ownership — no duplicate result lists outside Browse).
@MainActor
final class RootSearchHandoff {
    private var task: Task<Void, Never>?

    func schedule(_ query: String, launch: @escaping (String) -> Void) {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            launch(trimmed)
        }
    }

    func submit(_ query: String, launch: @escaping (String) -> Void) {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        launch(trimmed)
    }
}
