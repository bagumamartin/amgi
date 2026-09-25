// AmgiApp/Sources/Shared/CollectionChrome.swift
package import SwiftUI
import AmgiUI
import Foundation

// MARK: - Sync

/// Stable scene-local trigger installed by `.syncFlow()`. A class reference
/// keeps toolbar invalidation cheap and, unlike a process notification, opens
/// Sync only in the window where the user tapped.
package final class SyncPresentationAction: @unchecked Sendable {
    private var action: () -> Void
    package static let uninstalled = SyncPresentationAction {}

    package init(action: @escaping () -> Void = {}) {
        self.action = action
    }

    package func configure(action: @escaping () -> Void) {
        self.action = action
    }

    package func callAsFunction() {
        action()
    }
}

private struct SyncPresentationActionKey: EnvironmentKey {
    static let defaultValue = SyncPresentationAction.uninstalled
}

extension EnvironmentValues {
    package var presentSync: SyncPresentationAction {
        get { self[SyncPresentationActionKey.self] }
        set { self[SyncPresentationActionKey.self] = newValue }
    }
}

/// Standalone sync affordance for screens whose trailing slot carries the
/// ever-present sync glyph.
package struct SyncToolbarButton: View {
    @Environment(\.presentSync) private var presentSync

    package init() {}

    package var body: some View {
        Button {
            presentSync()
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
    /// does not use this (Mail-style persistent field); Read's book filter
    /// does.
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

    /// Large-title subtitle (Study’s weekday line). iOS 26 API; no-op
    /// on the iOS 18 deployment floor. macOS uses the AmgiUI shim.
    @ViewBuilder
    package func navigationSubtitleIfAvailable(_ subtitle: String) -> some View {
        if subtitle.isEmpty {
            self
        } else {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                self.navigationSubtitle(subtitle)
            } else {
                self
            }
            #else
            self.navigationSubtitle(subtitle)
            #endif
        }
    }

    /// Keep the full tab bar. iOS 26 can shrink it on scroll to a side
    /// button plus search; we opt out so Library…Browse stay equally visible.
    @ViewBuilder
    package func tabBarAlwaysVisibleIfAvailable() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
