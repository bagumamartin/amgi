import AmgiTheme
import AmgiUI
import AssistantFeature
import BrowseFeature
import TemplatesFeature
import ReaderFeature

#if os(macOS)
package import SwiftUI
package import AmgiAppCore

/// macOS Settings window: a source-list sidebar of panes (the classic
/// macOS preferences pattern) instead of the iOS drill-down `Form` of
/// navigation rows. Each pane is an existing settings screen, shown in the
/// detail column; pushes (e.g. template editor) happen inside a
/// `NavigationStack` within the detail.
package struct SettingsWindowHost: View {
    package let onSwitchProfile: (AmgiAccount) async -> Void
    @State private var selection: SettingsRoute? = .appearance
    @Bindable private var accountStore = AccountStore.shared
    @Bindable private var appLocale = AppLocaleModel.shared
    @Environment(\.palette) private var palette

    package init(onSwitchProfile: @escaping (AmgiAccount) async -> Void) {
        self.onSwitchProfile = onSwitchProfile
    }

    package var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsRouteInventory.availableGroups) { group in
                    Section(LocalizedStringKey(group.title)) {
                        ForEach(group.routes) { route in
                            Label(LocalizedStringKey(route.title), systemImage: route.systemImage)
                                .tag(route)
                                .accessibilityLabel(Text(LocalizedStringKey(route.title)))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .appSidebarWidth()
        } detail: {
            NavigationStack {
                if let selection {
                    detailView(for: selection)
                        // A source list gives the detail column its own
                        // breathing room; the cap also prevents long form
                        // rows from becoming unreadable on a wide window.
                        .settingsAdaptiveWidth()
                } else {
                    Text("Choose a setting")
                        .foregroundStyle(palette.textSecondary)
                        .settingsAdaptiveWidth()
                }
            }
        }
        .alert(
            "Couldn't switch profile",
            isPresented: $accountStore.hasSwitchFailure
        ) {
            Button("OK", role: .cancel) { accountStore.switchFailure = nil }
        } message: {
            Text(accountStore.switchFailure ?? "")
        }
        .environment(\.locale, appLocale.locale)
    }

    @ViewBuilder
    private func detailView(for route: SettingsRoute) -> some View {
        switch route {
        case .appearance:
            AppearanceSettingsView(manager: .shared)
        case .profiles:
            AccountsSettingsView(onSwitchProfile: onSwitchProfile)
        case .syncServer:
            SyncSettingsView()
        case .reviewBehavior:
            ReviewSettingsView()
        case .cardRendering:
            CardRenderingSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .assistant:
            AssistantSettingsView()
        case .readerDisplay:
            ReaderSettingsView()
        case .dictionaries:
            ReaderDictionarySettingsView()
        case .tags:
            TagsView()
        case .database:
            MaintenanceView()
        case .backups:
            BackupView(username: AccountStore.shared.current.displayName)
        case .emptyCards:
            EmptyCardsView()
        case .mediaCheck:
            MediaCheckResultView()
        case .manageTemplates:
            DeckTemplateListView()
        case .templateOverrides:
            TemplateOverridesView()
        case .codeEditor:
            CodeEditorSettingsView()
        case .agentMCP:
            MCPServerSettingsView()
        case .about:
            AboutView()
        }
    }
}

#endif
