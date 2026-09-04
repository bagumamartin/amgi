package import SwiftUI
import AmgiTheme
package import AmgiAppCore
import BrowseFeature
import TemplatesFeature
import ReaderFeature

#if os(macOS)

/// macOS Settings window: a source-list sidebar of panes (the classic
/// macOS preferences pattern) instead of the iOS drill-down `Form` of
/// navigation rows. Each pane is an existing settings screen, shown in the
/// detail column; pushes (e.g. template editor) happen inside a
/// `NavigationStack` within the detail.
package struct SettingsWindowHost: View {
    package let onSwitchProfile: (AmgiAccount) async -> Void
    @State private var selection: SettingsItem? = .appearance
    @Environment(\.palette) private var palette

    package init(onSwitchProfile: @escaping (AmgiAccount) async -> Void) {
        self.onSwitchProfile = onSwitchProfile
    }

    package var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSidebarGroup.all) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Label(item.title, systemImage: item.systemImage)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            NavigationStack {
                if let selection {
                    detailView(for: selection)
                } else {
                    Text("Choose a setting")
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detailView(for item: SettingsItem) -> some View {
        switch item {
        case .appearance: AppearanceSettingsView(manager: .shared)
        case .profiles: AccountsSettingsView(onSwitchProfile: onSwitchProfile)
        case .syncServer: SyncSettingsView()
        case .reviewBehavior: ReviewSettingsView()
        case .cardRendering: CardRenderingSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .readerDisplay: ReaderSettingsView()
        case .dictionaries: ReaderDictionarySettingsView()
        case .tags: TagsView()
        case .database: MaintenanceView()
        case .backups: BackupView(username: AccountStore.shared.current.displayName)
        case .emptyCards: EmptyCardsView()
        case .mediaCheck: MediaCheckResultView()
        case .manageTemplates: DeckTemplateListView()
        case .codeEditor: CodeEditorSettingsView()
        case .agentMCP: MCPServerSettingsView()
        case .about: AboutView()
        }
    }
}

/// One entry in the Settings sidebar.
private enum SettingsItem: String, CaseIterable, Identifiable {
    case appearance
    case profiles
    case syncServer
    case reviewBehavior
    case cardRendering
    case shortcuts
    case readerDisplay
    case dictionaries
    case tags
    case database
    case backups
    case emptyCards
    case mediaCheck
    case manageTemplates
    case codeEditor
    case agentMCP
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Theme & Appearance"
        case .profiles: "Profiles"
        case .syncServer: "Sync Server"
        case .reviewBehavior: "Review Behavior"
        case .cardRendering: "Card Rendering"
        case .shortcuts: "Shortcuts"
        case .readerDisplay: "Reader Display"
        case .dictionaries: "Dictionaries"
        case .tags: "Manage Tags"
        case .database: "Database"
        case .backups: "Backups"
        case .emptyCards: "Empty Cards"
        case .mediaCheck: "Media Check"
        case .manageTemplates: "Manage Templates"
        case .codeEditor: "Code Editor"
        case .agentMCP: "Agent (MCP)"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .profiles: "person.crop.circle"
        case .syncServer: "arrow.triangle.2.circlepath"
        case .reviewBehavior: "graduationcap"
        case .cardRendering: "square.on.square"
        case .shortcuts: "keyboard"
        case .readerDisplay: "book"
        case .dictionaries: "character.book.closed"
        case .tags: "tag"
        case .database: "internaldrive"
        case .backups: "externaldrive"
        case .emptyCards: "tray"
        case .mediaCheck: "photo.on.rectangle"
        case .manageTemplates: "square.and.pencil"
        case .codeEditor: "chevron.left.forwardslash.chevron.right"
        case .agentMCP: "cpu"
        case .about: "info.circle"
        }
    }
}

/// Sidebar grouping for the Settings source list.
private struct SettingsSidebarGroup: Identifiable {
    let title: String
    let items: [SettingsItem]

    var id: String { title }

    static let all: [SettingsSidebarGroup] = [
        SettingsSidebarGroup(title: "Appearance", items: [.appearance]),
        SettingsSidebarGroup(title: "Account", items: [.profiles, .syncServer]),
        SettingsSidebarGroup(title: "Review", items: [.reviewBehavior, .cardRendering, .shortcuts]),
        SettingsSidebarGroup(title: "Reader", items: [.readerDisplay, .dictionaries]),
        SettingsSidebarGroup(title: "Tags", items: [.tags]),
        SettingsSidebarGroup(title: "Maintenance", items: [.database, .backups, .emptyCards, .mediaCheck]),
        SettingsSidebarGroup(title: "Card Templates", items: [.manageTemplates, .codeEditor]),
        SettingsSidebarGroup(title: "Agent", items: [.agentMCP]),
        SettingsSidebarGroup(title: "About", items: [.about]),
    ]
}

#endif
