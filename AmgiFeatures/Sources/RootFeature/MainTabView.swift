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

/// The app's top-level sections. Shared by the iOS tab bar / iPad adaptable
/// sidebar and the macOS sidebar so menu commands (⌘1–5) stay in sync.
///
/// Browse fills the fifth slot. Settings lives in the sidebar footer
/// (profile capsule + gear) on Mac and on iPad while the adaptable sidebar
/// is showing. When that sidebar collapses to the top tab bar — and on
/// iPhone — profile and Settings combine in the leading toolbar. macOS
/// also exposes Settings from the menu bar.
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
/// Platform idiom: iPhone keeps the bottom tab bar; iPad uses
/// `.sidebarAdaptable` (Browse takes the window over at regular width so
/// its three columns aren't nested in that sidebar); macOS uses a
/// `NavigationSplitView` with the profile row at the bottom.
struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let refreshID: UUID
    let showReaderTab: Bool
    let onSelectStudyDeck: (DeckID) -> Void

    /// Persisted so menu commands and the sidebar share one source of truth.
    @Shared(.appStorage(NavigationPreferences.rootSection)) private var sectionRaw: String = MainSection.study.rawValue

    /// Consume drill-in launch requests (deck detail "Browse", deep links)
    /// by switching sections; BrowseView clears after consuming.
    @State private var browseRequest = BrowseLauncher.shared

    /// Section to return to when Browse hands a regular-width window back.
    @State private var previousSection: MainSection = .library

    /// Settings push from the sidebar footer. On macOS the footer opens the
    /// Settings window instead of writing this.
    @State private var accountDestination: AccountMenuDestination?

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

    /// iOS `List(selection:)` only accepts an Optional. Clearing the
    /// selection is ignored so a section is always active.
    private var sidebarSelection: Binding<MainSection?> {
        Binding(
            get: { selection },
            set: { newSection in
                if let newSection {
                    selectionBinding.wrappedValue = newSection
                }
            }
        )
    }

    /// Mac always; iPad Browse at regular width takes the window over.
    private var usesBrowseTakeover: Bool {
        #if os(macOS)
        selection == .browse
        #else
        horizontalSizeClass == .regular && selection == .browse
        #endif
    }

    var body: some View {
        Group {
            if usesBrowseTakeover {
                browseTakeover
            } else {
                #if os(macOS)
                splitRoot
                #else
                iosTabView
                #endif
            }
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

    private var browseTakeover: some View {
        BrowseView(exit: BrowseExit(
            title: previousSection.title,
            systemImage: previousSection.systemImage,
            action: { selectionBinding.wrappedValue = previousSection }
        ))
    }

    /// Section list + profile/Settings chips. Settings pushes on the
    /// detail stack (same as iPhone), not a stack wrapping the split —
    /// wrapping `NavigationSplitView` in `NavigationStack` ate Library's
    /// deck-detail `navigationDestination`.
    private var splitRoot: some View {
        NavigationSplitView {
            rootSidebar
        } detail: {
            sectionContent(selection, showsAccountMenu: false)
        }
    }

    private var rootSidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(sections) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .appSidebarWidth()
        .accountSidebarFooter(open: $accountDestination)
    }

    #if os(iOS)
    private var iosTabView: some View {
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
            Tab(MainSection.browse.title, systemImage: MainSection.browse.systemImage, value: MainSection.browse) {
                tabContent(for: .browse)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tabBarAlwaysVisibleIfAvailable()
        .tabViewSidebarBottomBar {
            AccountSidebarFooterHost(open: $accountDestination)
        }
    }
    #endif

    @ViewBuilder
    private func sectionContent(_ section: MainSection, showsAccountMenu: Bool) -> some View {
        switch section {
        case .library:
            NavigationStack {
                DeckListView(onOpenToday: {
                    $sectionRaw.withLock { $0 = MainSection.study.rawValue }
                })
                    .accountChrome(showsMenu: showsAccountMenu, destination: $accountDestination)
            }
        case .read:
            NavigationStack {
                ReaderLibraryView(refreshID: refreshID)
                    .accountChrome(showsMenu: showsAccountMenu, destination: $accountDestination)
            }
        case .study:
            NavigationStack {
                StudyLandingView(
                    onSelectDeck: onSelectStudyDeck,
                    onOpenLibrary: {
                        $sectionRaw.withLock { $0 = MainSection.library.rawValue }
                    },
                    showsContinueReading: showReaderTab
                )
                    .accountChrome(showsMenu: showsAccountMenu, destination: $accountDestination)
            }
        case .stats:
            NavigationStack {
                StatsDashboardView(refreshID: refreshID)
                    .accountChrome(showsMenu: showsAccountMenu, destination: $accountDestination)
            }
        case .browse:
            // BrowseView is itself a NavigationSplitView. Wrapping it in
            // another stack blanks compact and steals column destinations.
            BrowseView()
        }
    }

    @ViewBuilder
    private func tabContent(for section: MainSection) -> some View {
        #if os(iOS)
        TabAccountChrome { showsMenu in
            sectionContent(section, showsAccountMenu: showsMenu)
        }
        #else
        sectionContent(section, showsAccountMenu: false)
        #endif
    }
}

private extension View {
    /// Combined profile + Settings in the leading toolbar when the adaptable
    /// bar is a tab bar. Sidebar placement uses the bottom-bar chips instead.
    @ViewBuilder
    func accountChrome(
        showsMenu: Bool,
        destination: Binding<AccountMenuDestination?>
    ) -> some View {
        if showsMenu {
            accountMenu()
        } else {
            accountMenuDestinations(destination)
        }
    }
}

#if os(iOS)
/// `tabBarPlacement` is only set inside TabView content. Sidebar → footer
/// chips; top/bottom tab bar → the combined leading profile menu.
private struct TabAccountChrome<Content: View>: View {
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(tabBarPlacement != .sidebar)
    }
}
#endif
