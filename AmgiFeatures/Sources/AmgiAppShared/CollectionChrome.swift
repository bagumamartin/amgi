// AmgiApp/Sources/Shared/CollectionChrome.swift
package import SwiftUI
import AmgiUI
public import Foundation

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
