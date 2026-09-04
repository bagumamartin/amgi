import AmgiAppCore
import AmgiAppShared
import AnkiKit
import BrowseFeature
import DecksFeature
import ReaderFeature
import SettingsFeature
import Sharing
import StatsFeature
import SwiftUI
import AmgiUI
import SyncFeature

/// The app's top-level sections. Shared by the iOS tab bar and the macOS
/// sidebar so menu commands (⌘1–5) and the root switcher stay in sync.
///
/// Browse fills the fifth slot; Settings lives in every root's account
/// menu (`ProfilePickerMenu`) plus the menu bar on macOS / iPadOS 26+.
enum MainSection: String, CaseIterable, Identifiable {
    case library, read, study, stats, browse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .read: "Read"
        case .study: "Study"
        case .stats: "Stats"
        case .browse: "Browse"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .read: "book"
        case .study: "graduationcap"
        case .stats: "chart.bar"
        case .browse: "magnifyingglass"
        }
    }
}

/// Root navigation. Pure layout: each section wraps a feature view in a
/// `NavigationStack`. `refreshID` is *handed to* the tabs that still reload
/// from it (Read, Stats), not applied as `.id()`. As an `.id()` it discarded
/// each tab's whole subtree — scroll position, search text, selected deck,
/// pushed navigation. Library and Study reload via `CollectionStore`.
///
/// Platform idiom: iPhone keeps the bottom tab bar, iPad gets
/// `.sidebarAdaptable`, and macOS uses a `NavigationSplitView` sidebar.
struct MainTabView: View {
    let refreshID: UUID
    let showReaderTab: Bool
    let onImport: () -> Void
    let onSelectStudyDeck: (DeckID) -> Void

    @Environment(\.startSync) private var startSync

    /// Persisted so menu commands and the sidebar share one source of truth.
    @Shared(.appStorage(NavigationPreferences.rootSection)) private var sectionRaw: String = MainSection.study.rawValue

    /// Consume drill-in launch requests (deck detail "Browse", deep links)
    /// by switching sections; BrowseView clears after consuming.
    @State private var browseRequest = BrowseLauncher.shared

    /// Section to return to when Browse hands the macOS window back.
    @State private var previousSection: MainSection = .library

    private var sections: [MainSection] {
        MainSection.allCases.filter { section in
            if case .read = section { return showReaderTab }
            return true
        }
    }

    private var selection: MainSection {
        MainSection(rawValue: sectionRaw) ?? .study
    }

    /// Writes the `@Shared` raw value directly (nonmutating), so the binding
    /// closures can escape without capturing a mutable `self`.
    private var selectionBinding: Binding<MainSection> {
        Binding(
            get: { selection },
            set: { newSection in
                $sectionRaw.withLock { $0 = newSection.rawValue }
            }
        )
    }

    var body: some View {
        Group {
            #if os(macOS)
            // Browse TAKES OVER the window: it is itself a three-column
            // NavigationSplitView. Nesting that inside this one produced four
            // competing columns.
            if selection == .browse {
                BrowseView(exit: BrowseExit(
                    title: previousSection.title,
                    systemImage: previousSection.systemImage,
                    action: { selectionBinding.wrappedValue = previousSection }
                ))
            } else {
                NavigationSplitView {
                    List(selection: selectionBinding) {
                        ForEach(sections) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
                } detail: {
                    sectionContent(selection)
                }
            }
            #else
            TabView(selection: selectionBinding) {
                Tab(MainSection.library.title, systemImage: MainSection.library.systemImage, value: MainSection.library) {
                    tabContent(for: .library)
                }
                if showReaderTab {
                    Tab(MainSection.read.title, systemImage: MainSection.read.systemImage, value: MainSection.read) {
                        tabContent(for: .read)
                    }
                }
                Tab(MainSection.study.title, systemImage: MainSection.study.systemImage, value: MainSection.study) {
                    tabContent(for: .study)
                }
                Tab(MainSection.stats.title, systemImage: MainSection.stats.systemImage, value: MainSection.stats) {
                    tabContent(for: .stats)
                }
                Tab(value: MainSection.browse, role: .search) {
                    tabContent(for: .browse)
                } label: {
                    Label(MainSection.browse.title, systemImage: MainSection.browse.systemImage)
                        .fontWeight(.heavy)
                        .symbolVariant(.fill)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizedOnScrollIfAvailable()
            #endif
        }
        .onChange(of: selection) { oldValue, newValue in
            if newValue == .browse, oldValue != .browse {
                previousSection = oldValue
            }
        }
        .onChange(of: browseRequest.requestID) {
            selectionBinding.wrappedValue = .browse
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: MainSection) -> some View {
        switch section {
        case .library:
            NavigationStack {
                DeckListView(onSwitchProfile: { await switchProfile(to: $0) })
                    .accountMenu()
                    .toolbar { libraryToolbar }
            }
        case .read:
            NavigationStack {
                ReaderLibraryView(refreshID: refreshID)
                    .accountMenu()
            }
        case .study:
            NavigationStack {
                StudyLandingView(onSelectDeck: onSelectStudyDeck)
            }
        case .stats:
            NavigationStack {
                StatsDashboardView(refreshID: refreshID)
                    .accountMenu()
            }
        case .browse:
            // No NavigationStack wrapper: compact BrowseView roots its own
            // stack (required for the iOS 26 search-tab morph).
            BrowseView()
        }
    }

    @ViewBuilder
    private func tabContent(for section: MainSection) -> some View {
        sectionContent(section)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { startSync() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .accessibilityLabel("Sync")
            .help("Sync")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onImport) {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import deck")
            .help("Import deck")
        }
    }
}
