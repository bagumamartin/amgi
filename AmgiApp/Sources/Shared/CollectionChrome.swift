// AmgiApp/Sources/Shared/CollectionChrome.swift
import SwiftUI

// MARK: - Sync

/// Standalone sync affordance for screens whose trailing slot carries the
/// ever-present sync glyph. Posts the app-wide `.amgiPresentSync` rail
/// consumed by ContentView, so every concerned screen reaches the same
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
