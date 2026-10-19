import AssistantFeature
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
/// `NavigationStack`, except Library and Browse, which own their split. `refreshID` is *handed to* the tabs that still reload
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
    let sceneActions: RootSceneActions
    let refreshID: UUID
    let showReaderTab: Bool
    let studyTodayRequest: Int
    let studyTodayDeckID: Int64?
    @Binding var libraryDeckRequest: Int64?
    let onSelectStudyDeck: (DeckID) -> Void
    let onPullCooling: () -> Void
    let onOpenAssistant: @MainActor ([AssistantContext]) -> Void
    var assistantIsPresented = false
    @State private var screenContext: [AssistantContext] = []
    @State private var captureKind: QuickCaptureKind?
    @State private var showsCaptureOptions = false
    @State private var captureRowFrame: CGRect = .zero
    @State private var captureButtonFrame: CGRect = .zero

    /// Persisted so menu commands and the sidebar share one source of truth.
    @Shared(.appStorage(NavigationPreferences.rootSection)) private var sectionRaw: String = MainSection.study.rawValue

    /// Consume drill-in launch requests (deck detail "Browse", deep links)
    /// by switching sections; BrowseView clears after consuming.
    @State private var browseRequest = BrowseLauncher.shared

    /// Section to return to when Browse hands a regular-width window back.
    @State private var previousSection: MainSection = .library

    /// An open book takes the window on Mac: the section sidebar collapses
    /// (a PDF shows its own page sidebar instead, as Preview does) and comes
    /// back when the book closes.
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var readerWindowState = ReaderWindowState()

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
                if selection == .library {
                    libraryRoot
                } else {
                    splitRoot
                }
                #else
                iosTabView
                #endif
            }
        }
        #if os(iOS)
        // Here rather than on `iosTabView` so the iPad Browse takeover, which
        // replaces the tab view, still gets the fan-out. Below the floating
        // entry, so its `×` stays on top.
        .overlay {
            QuickCaptureOverlay(
                isPresented: $showsCaptureOptions,
                rowFrame: captureRowFrame,
                buttonFrame: captureButtonFrame,
                capture: { captureKind = $0 }
            )
        }
        #endif
        .overlay(alignment: .bottomTrailing) {
            // Readers own this corner — their menu, card dock, and their own
            // Ask AI button live there — so the whole entry steps aside.
            if usesFloatingEntry && !assistantIsPresented && !screenContext.isReader {
                #if os(iOS)
                FloatingAssistantEntry(
                    openAssistant: openAssistant,
                    capture: { captureKind = $0 },
                    showsCapture: $showsCaptureOptions,
                    onRowFrame: { captureRowFrame = $0 },
                    onCaptureButtonFrame: { captureButtonFrame = $0 }
                )
                .padding(20)
                #else
                FloatingAssistantEntry(openAssistant: openAssistant, capture: { captureKind = $0 })
                    .padding(20)
                #endif
            }
        }
        .environment(\.assistantOpener, AssistantOpener(onOpenAssistant))
        .onPreferenceChange(AssistantScreenContextKey.self) { screenContext = $0 }
        .onAppear { sceneActions.presentSettings = { accountDestination = .settings } }
        .sheet(item: $captureKind) { QuickCaptureView(kind: $0) }
        .onChange(of: selection) { oldValue, newValue in
            screenContext = []
            showsCaptureOptions = false
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
        .accountChrome(
            showsMenu: false,
            destination: $accountDestination,
            openAssistant: openAssistant
        )
    }

    /// Section list + profile/Settings chips. Settings pushes on the
    /// detail stack (same as iPhone), not a stack wrapping the split —
    /// wrapping `NavigationSplitView` in `NavigationStack` ate Library's
    /// deck-detail `navigationDestination`.
    private var splitRoot: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            rootSidebar
                // An open book has the window to itself; a PDF's own page
                // sidebar has its own button, and a second toggle beside it
                // would only bring the section list back over the book.
                .toolbar(removing: readerWindowState.isActive ? .sidebarToggle : nil)
        } detail: {
            sectionContent(selection, showsAccountMenu: false)
        }
        .environment(\.readerWindowState, readerWindowState)
        .onChange(of: readerWindowState.isActive) { _, isActive in
            splitColumnVisibility = isActive ? .detailOnly : .all
        }
    }

    #if os(macOS)
    /// Library is a list-and-detail screen, so on Mac it takes the window as
    /// a three-column split around the same section sidebar — the way Mail
    /// and Notes do — instead of nesting a second split in the detail.
    private var libraryRoot: some View {
        DeckListView(
            openDeckID: $libraryDeckRequest,
            sidebar: AnyView(rootSidebar),
            columnChrome: libraryColumnChrome(showsMenu: false)
        )
    }
    #endif

    /// The account chrome for Library's list column. Library owns its
    /// navigation container (stack or split), so the chrome goes in through
    /// it rather than around it.
    private func libraryColumnChrome(showsMenu: Bool) -> (AnyView, Bool) -> AnyView {
        let destination = $accountDestination
        let openAssistant: () -> Void = openAssistant
        return { column, includesMenu in
            AnyView(column.accountChrome(
                showsMenu: showsMenu && includesMenu,
                destination: destination,
                openAssistant: openAssistant
            ))
        }
    }

    /// The screen's own context when it has one; otherwise what the section
    /// itself is about. Either is a chip the user can remove.
    private func openAssistant() { onOpenAssistant(screenContext.isEmpty ? [sectionContext] : screenContext) }

    private var sectionContext: AssistantContext {
        switch selection {
        case .library: .library
        case .study: .today
        case .read, .stats, .browse: .collection
        }
    }

    private var usesFloatingEntry: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass != .compact
        #endif
    }

    private var rootSidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(sections) { section in
                Label(LocalizedStringKey(section.title), systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .appSidebarWidth()
        .accountSidebarFooter(open: $accountDestination)
    }

    #if os(iOS)
    /// Outline when inactive, filled when selected. The tab bar fills every
    /// symbol by default, so the variant is pinned per tab from the selection.
    private func tabLabel(_ section: MainSection) -> some View {
        Label(LocalizedStringKey(section.title), systemImage: section.systemImage)
            .environment(\.symbolVariants, selection == section ? .fill : .none)
    }

    private var iosTabView: some View {
        TabView(selection: selectionBinding) {
            Tab(value: MainSection.library) {
                tabContent(for: .library)
            } label: { tabLabel(.library) }
            if showReaderTab {
                Tab(value: MainSection.read) {
                    tabContent(for: .read)
                } label: { tabLabel(.read) }
            }
            Tab(value: MainSection.study) {
                tabContent(for: .study)
            } label: { tabLabel(.study) }
            Tab(value: MainSection.stats) {
                tabContent(for: .stats)
            } label: { tabLabel(.stats) }
            Tab(value: MainSection.browse) {
                tabContent(for: .browse)
            } label: { tabLabel(.browse) }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tabBarMinimizeBehavior(.onScrollDown)
        .assistantEntryAccessory(isEnabled: horizontalSizeClass == .compact && !screenContext.isReader) {
            AssistantEntryRow(
                openAssistant: openAssistant,
                showsCapture: $showsCaptureOptions,
                onRowFrame: { captureRowFrame = $0 },
                onCaptureButtonFrame: { captureButtonFrame = $0 }
            )
        }
        .tabViewSidebarBottomBar {
            AccountSidebarFooterHost(open: $accountDestination)
        }
    }
    #endif

    @ViewBuilder
    private func sectionContent(_ section: MainSection, showsAccountMenu: Bool) -> some View {
        switch section {
        case .library:
            // No stack here: Library switches between a stack and a split
            // on its own, and a split inside a stack loses its columns.
            DeckListView(
                openDeckID: $libraryDeckRequest,
                columnChrome: libraryColumnChrome(showsMenu: showsAccountMenu)
            )
        case .read:
            NavigationStack {
                ReaderLibraryView(refreshID: refreshID)
                    .accountChrome(
                        showsMenu: showsAccountMenu,
                        destination: $accountDestination,
                        openAssistant: openAssistant
                    )
            }
        case .study:
            NavigationStack {
                StudyLandingView(
                    onSelectDeck: onSelectStudyDeck,
                    onOpenLibrary: {
                        $sectionRaw.withLock { $0 = MainSection.library.rawValue }
                    },
                    showsContinueReading: showReaderTab,
                    onPullCooling: onPullCooling,
                    todayRequest: studyTodayRequest,
                    todayDeckID: studyTodayDeckID
                )
                    .accountChrome(
                        showsMenu: showsAccountMenu,
                        destination: $accountDestination,
                        openAssistant: openAssistant
                    )
            }
        case .stats:
            NavigationStack {
                StatsDashboardView(refreshID: refreshID)
                    .accountChrome(
                        showsMenu: showsAccountMenu,
                        destination: $accountDestination,
                        openAssistant: openAssistant
                    )
            }
        case .browse:
            // BrowseView is itself a NavigationSplitView. Wrapping it in
            // another stack blanks compact and steals column destinations,
            // but its own chrome still needs the assistant entry point.
            BrowseView()
                .accountChrome(
                    showsMenu: showsAccountMenu,
                    destination: $accountDestination,
                    openAssistant: openAssistant
                )
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
    ///
    /// One modifier chain for both placements: only the toolbar item toggles.
    /// An `if` choosing between two chains gave the screen a new identity each
    /// time the iPad sidebar collapsed into the tab bar, so every screen
    /// rebuilt its model, reloaded, and replayed its entrance animations.
    func accountChrome(
        showsMenu: Bool,
        destination: Binding<AccountMenuDestination?>,
        openAssistant: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        accountMenuControl(open: destination, isVisible: showsMenu)
            .accountMenuDestinations(destination)
        #else
        accountMenuDestinations(destination)
        #endif
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
