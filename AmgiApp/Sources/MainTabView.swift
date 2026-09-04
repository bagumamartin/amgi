// AmgiApp/Sources/MainTabView.swift
import SwiftUI
import AnkiKit
import Sharing

/// The app's top-level sections. Shared by the iOS tab bar and the macOS
/// sidebar so menu commands (⌘1–5) and the root switcher stay in sync.
///
/// Browse fills the fifth slot; Settings lives in every root's account
/// menu (`ProfilePickerMenu`) plus the menu bar on macOS / iPadOS 26+
/// (browse-redesign-spec D1/D2).
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
/// `NavigationStack`. `refreshID` (bumped by the host after sync / import /
/// review) now only drives the sections not yet on `CollectionStore` —
/// Library and Study reload via the store's generation instead. All side
/// effects are forwarded to the host via closures so this view owns no I/O
/// or sync state.
///
/// Platform idiom (per the HIGs): iPhone keeps the bottom tab bar, iPad gets
/// the adaptive sidebar/tab bar (`.sidebarAdaptable`), and macOS uses a
/// `NavigationSplitView` sidebar — the iOS `TabView` renders no visible
/// chrome on macOS, which strands the user on the first tab.
struct MainTabView: View {
    let refreshID: UUID
    let showReaderTab: Bool
    let onSync: () -> Void
    let onImport: () -> Void
    let onSelectStudyDeck: (DeckID) -> Void

    /// Persisted so menu commands and the sidebar share one source of truth.
    @Shared(.appStorage(NavigationPreferences.rootSection)) private var sectionRaw: String = MainSection.study.rawValue

    /// Consume drill-in launch requests (deck detail "Browse", deep links)
    /// by switching sections; BrowseView clears after consuming.
    @State private var browseRequest = BrowseLauncher.shared

    /// Section to return to when Browse hands the macOS window back. Browse
    /// replaces the root sidebar while it's active, so its own sidebar header
    /// is the way out and it needs to know where "back" points.
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
            // NavigationSplitView, and nesting that inside this one produced
            // four competing columns (the notes list collapsed to a sliver and
            // toolbar items landed above the wrong pane). Its sidebar replaces
            // this one, with a header row back to `previousSection`.
            if selection == .browse {
                BrowseView(exit: BrowseExit(
                    title: previousSection.title,
                    systemImage: previousSection.systemImage,
                    action: { selectionBinding.wrappedValue = previousSection }
                ))
                .id(refreshID)
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
            // iPadOS HIG: adaptive sidebar/tab bar on regular width; iPhone
            // keeps the compact bottom tab bar.
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizedOnScrollIfAvailable()
            #endif
        }
        .onChange(of: selection) { oldValue, newValue in
            // Catches every route into Browse — sidebar, ⌘1–5, deep links —
            // so the sidebar header always points back where the user was.
            if newValue == .browse, oldValue != .browse {
                previousSection = oldValue
            }
        }
        .onChange(of: browseRequest.requestID) {
            // A drill-in arrived from any root: surface Browse now; the
            // query payload is picked up when its view appears.
            selectionBinding.wrappedValue = .browse
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: MainSection) -> some View {        switch section {
        case .library:
            NavigationStack {
                DeckListView(onStartReview: { onSelectStudyDeck(DeckID(0)) })
                    .accountMenu()
                    .toolbar { libraryToolbar }
            }
        case .read:
            NavigationStack {
                ReaderLibraryView()
                    .id(refreshID)
                    .accountMenu()
            }
        case .study:
            NavigationStack {
                StudyLandingView(onSelectDeck: onSelectStudyDeck)
                    .id(refreshID)
            }
        case .stats:
            NavigationStack {
                StatsDashboardView()
                    .id(refreshID)
                    .accountMenu()
            }
        case .browse:
            // No NavigationStack wrapper: compact BrowseView roots its own
            // stack (required for the iOS 26 search-tab morph), and regular
            // width is a NavigationSplitView. Wrapping either re-creates the
            // nesting that broke the layout. On macOS this case is unreachable
            // — the window-takeover branch in `body` handles Browse.
            BrowseView()
                .id(refreshID)
        }
    }

    @ViewBuilder
    private func tabContent(for section: MainSection) -> some View {
        sectionContent(section)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onSync) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Sync")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onImport) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Import deck")
        }
    }
}
