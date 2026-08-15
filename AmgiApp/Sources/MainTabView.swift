// AmgiApp/Sources/MainTabView.swift
import SwiftUI
import AnkiKit
import Sharing

/// The app's top-level sections. Shared by the iOS tab bar and the macOS
/// sidebar so menu commands (⌘1–5) and the root switcher stay in sync.
enum MainSection: String, CaseIterable, Identifiable {
    case library, read, study, stats, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .read: "Read"
        case .study: "Study"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .read: "book"
        case .study: "graduationcap"
        case .stats: "chart.bar"
        case .settings: "gearshape"
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
    @Shared(.appStorage("amgi.root.section")) private var sectionRaw: String = MainSection.study.rawValue

    private var sections: [MainSection] {
        MainSection.allCases.filter { $0 != .read || showReaderTab }
    }

    private var selection: MainSection {
        MainSection(rawValue: sectionRaw) ?? .study
    }

    /// Writes the `@Shared` raw value directly (nonmutating), so the binding
    /// closures can escape without capturing a mutable `self`.
    private var selectionBinding: Binding<MainSection> {
        Binding(
            get: { MainSection(rawValue: sectionRaw) ?? .study },
            set: { sectionRaw = $0.rawValue }
        )
    }

    var body: some View {
        #if os(macOS)
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
        #else
        TabView(selection: selectionBinding) {
            ForEach(sections) { section in
                Tab(section.title, systemImage: section.systemImage, value: section) {
                    sectionContent(section)
                }
            }
        }
        // iPadOS HIG: adaptive sidebar/tab bar on regular width; iPhone
        // keeps the compact bottom tab bar.
        .tabViewStyle(.sidebarAdaptable)
        #endif
    }

    @ViewBuilder
    private func sectionContent(_ section: MainSection) -> some View {
        switch section {
        case .library:
            NavigationStack {
                DeckListView()
                    .toolbar { libraryToolbar }
            }
        case .read:
            NavigationStack {
                ReaderLibraryView()
                    .id(refreshID)
            }
        case .study:
            NavigationStack {
                StudyLandingView(onSelectDeck: onSelectStudyDeck)
            }
        case .stats:
            NavigationStack {
                StatsDashboardView()
                    .id(refreshID)
            }
        case .settings:
            NavigationStack {
                SettingsView()
                    .id(refreshID)
            }
        }
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
