package import SwiftUI
import AmgiTheme
import AmgiUI
package import AmgiAppCore
import AssistantFeature
import BrowseFeature
import TemplatesFeature
import ReaderFeature

/// Settings, following the `amgi-settings.jsx` screen in the Amgi design
/// project: grouped inset panels, tinted glyph tiles, trailing values,
/// hairline footer. Title lives in the navigation bar so a push from any
/// root (profile switcher on Library / Study / …) still has a Back.
///
/// The route metadata comes from `SettingsRouteInventory`, the same
/// catalogue used by the macOS source list. This page is still arranged into
/// the design's iOS sections, but adding a route cannot make the two
/// platforms drift apart silently.
package struct SettingsView: View {
    private let onSwitchProfile: (AmgiAccount) async -> Void

    /// - Parameter onSwitchProfile: profile switching closes/reopens the
    ///   collection, cancels sync and flips the keychain anchor — composition-
    ///   root work that lives in `RootFeature/ProfileSwitching.swift`.
    package init(onSwitchProfile: @escaping (AmgiAccount) async -> Void) {
        self.onSwitchProfile = onSwitchProfile
    }

    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedRoute: SettingsRoute? = .appearance

    package var body: some View {
        GeometryReader { proxy in
            let layout = SettingsContentLayout.resolve(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            Group {
                if layout == .split {
                    splitLayout
                } else {
                    compactLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .amgiScreenCanvas()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        #if os(iOS)
        .toolbarVisibility(.visible, for: .navigationBar)
        #endif
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appearanceSection
                accountSection
                studySection
                intelligenceSection
                readerSection
                maintenanceSection
                aboutSection
                footer
            }
            .settingsAdaptiveWidth()
            .padding(.bottom, AmgiSpacing.xl)
        }
    }

    /// iPad and Mac-sized settings use the same route catalogue as the
    /// macOS Settings window, but as a lightweight two-column workspace. The
    /// root shell already owns navigation, so this is an HStack rather than a
    /// second `NavigationSplitView`.
    private var splitLayout: some View {
        HStack(spacing: 0) {
            List(selection: $selectedRoute) {
                ForEach(SettingsRouteInventory.availableGroups) { group in
                    Section(LocalizedStringKey(group.title)) {
                        ForEach(group.routes) { route in
                            Label(LocalizedStringKey(route.title), systemImage: route.systemImage)
                                .tag(route)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)

            Divider()

            ScrollView {
                Group {
                    if let selectedRoute {
                        detailView(for: selectedRoute)
                    } else {
                        Text("Choose a setting")
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .settingsAdaptiveWidth()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 12)
                .padding(.bottom, AmgiSpacing.xl)
            }
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Group {
            SettingsSectionHeader(title: "Appearance")
            SettingsGroup {
                routeLink(.appearance, detail: themeName) {
                    AppearanceSettingsView(manager: .shared)
                }
                SettingsSeparator()
                routeLink(.readerDisplay) {
                    ReaderSettingsView()
                }
            }
        }
    }

    private var accountSection: some View {
        Group {
            SettingsSectionHeader(title: "Account")
            SettingsGroup {
                routeLink(.profiles, detail: AccountStore.shared.current.displayName) {
                    AccountsSettingsView(onSwitchProfile: onSwitchProfile)
                }
                SettingsSeparator()
                routeLink(.syncServer) {
                    SyncSettingsView()
                }
            }
        }
    }

    private var studySection: some View {
        Group {
            SettingsSectionHeader(title: "Study")
            SettingsGroup {
                routeLink(.reviewBehavior) {
                    ReviewSettingsView()
                }
                SettingsSeparator()
                routeLink(.cardRendering) {
                    CardRenderingSettingsView()
                }
                SettingsSeparator()
                routeLink(.shortcuts) {
                    ShortcutsSettingsView()
                }
                SettingsSeparator()
                routeLink(.manageTemplates) {
                    DeckTemplateListView()
                }
                SettingsSeparator()
                routeLink(.templateOverrides) {
                    TemplateOverridesView()
                }
                SettingsSeparator()
                routeLink(.codeEditor) {
                    CodeEditorSettingsView()
                }
            }
        }
    }

    private var intelligenceSection: some View {
        Group {
            SettingsSectionHeader(title: "Apple Intelligence")
            SettingsGroup {
                routeLink(.assistant, detail: FoundationModelService.availability.title) {
                    AssistantSettingsView()
                }
            }
        }
    }

    private var readerSection: some View {
        Group {
            SettingsSectionHeader(title: "Reader")
            SettingsGroup {
                routeLink(.dictionaries) {
                    ReaderDictionarySettingsView()
                }
            }
        }
    }

    private var maintenanceSection: some View {
        Group {
            SettingsSectionHeader(title: "Maintenance")
            SettingsGroup {
                routeLink(.tags) {
                    TagsView()
                }
                SettingsSeparator()
                routeLink(.database) {
                    MaintenanceView()
                }
                SettingsSeparator()
                routeLink(.emptyCards) {
                    EmptyCardsView()
                }
                SettingsSeparator()
                routeLink(.backups) {
                    BackupView(username: AccountStore.shared.current.displayName)
                }
                SettingsSeparator()
                routeLink(.mediaCheck) {
                    MediaCheckResultView()
                }
            }
        }
    }

    private var aboutSection: some View {
        Group {
            SettingsSectionHeader(title: "About")
            SettingsGroup {
                routeLink(.about, detail: appVersion) {
                    AboutView()
                }
            }
        }
    }

    private var footer: some View {
        Text("Ijuka · v\(appVersion) · Built with care")
            .amgiFont(.micro)
            .foregroundStyle(palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)
            .padding(.bottom, AmgiSpacing.sm)
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

    // MARK: - Shared route metadata

    /// Every navigation row gets its labels and icon from the shared route
    /// inventory, so the iOS drill-down and macOS source list cannot drift.
    private func routeLink<Destination: View>(
        _ route: SettingsRoute,
        detail: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        SettingsRowLink(
            title: route.title,
            systemImage: route.systemImage,
            tone: route.tone,
            detail: detail,
            destination: destination
        )
    }

    // MARK: - Trailing values

    /// Only values the screen can state with certainty are shown. The mock
    /// also puts a value on Reader Display, Sync Server and Dictionaries;
    /// those need state this screen doesn't own, so they stay blank rather
    /// than guess.
    private var themeName: String {
        let id = ThemeManager.shared.themeID.rawValue
        return ThemeRegistry.shared.allThemes()
            .first { $0.id == id }?
            .displayName ?? "—"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

enum SettingsContentLayout: Equatable {
    case compact
    case split

    static let minimumSplitWidth: CGFloat = 700

    static func resolve(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> SettingsContentLayout {
        guard !isAccessibilitySize, availableWidth >= minimumSplitWidth else {
            return .compact
        }
        return .split
    }
}

#if DEBUG

#Preview {
    NavigationStack {
        SettingsView(onSwitchProfile: { _ in })
    }
}
#endif
