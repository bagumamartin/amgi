public import SwiftUI
import AmgiTheme
public import AmgiAppCore
import BrowseFeature
import TemplatesFeature
import ReaderFeature

/// Settings, following the `amgi-settings.jsx` screen in the Amgi design
/// project: in-content large title, grouped inset panels, tinted glyph
/// tiles, trailing values, hairline footer.
///
/// Row inventory is the app's real screens rather than the mock's — the
/// mock names four destinations that don't exist (Privacy & Data, a global
/// FSRS Scheduler, an auto-card-from-highlights toggle, onboarding replay)
/// and omits three that do (Backups, Media Check, Code Editor).
public struct SettingsView: View {
    private let onSwitchProfile: (AmgiAccount) async -> Void

    /// - Parameter onSwitchProfile: profile switching closes/reopens the
    ///   collection, cancels sync and flips the keychain anchor — composition-
    ///   root work that stays in `AmgiAppApp.swift`. Same shape as
    ///   `DeckListView.onSwitchProfile`.
    public init(onSwitchProfile: @escaping (AmgiAccount) async -> Void) {
        self.onSwitchProfile = onSwitchProfile
    }

    @Environment(\.palette) private var palette

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                appearanceSection
                accountSection
                studySection
                readerSection
                maintenanceSection
                aboutSection
                footer
            }
            .padding(.bottom, AmgiSpacing.xl)
        }
        .background(palette.background)
        .toolbarVisibility(.hidden, for: .navigationBar)
    }

    // MARK: - Title

    private var title: some View {
        Text("Settings")
            .amgiFont(.displayHero)
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 20)
            .padding(.top, AmgiSpacing.sm)
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Group {
            SettingsSectionHeader(title: "Appearance")
            SettingsGroup {
                SettingsRowLink(
                    title: "Theme & Appearance",
                    systemImage: "paintpalette",
                    tone: .mature,
                    detail: themeName
                ) {
                    AppearanceSettingsView(manager: .shared)
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Reader Display",
                    systemImage: "book",
                    tone: .learning
                ) {
                    ReaderSettingsView()
                }
            }
        }
    }

    private var accountSection: some View {
        Group {
            SettingsSectionHeader(title: "Account")
            SettingsGroup {
                SettingsRowLink(
                    title: "Profiles",
                    systemImage: "person.crop.circle",
                    tone: .accent,
                    detail: AccountStore.shared.current.displayName
                ) {
                    AccountsSettingsView(onSwitchProfile: onSwitchProfile)
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Sync Server",
                    systemImage: "arrow.triangle.2.circlepath",
                    tone: .info
                ) {
                    SyncSettingsView()
                }
            }
        }
    }

    private var studySection: some View {
        Group {
            SettingsSectionHeader(title: "Study")
            SettingsGroup {
                SettingsRowLink(
                    title: "Review Behavior",
                    systemImage: "timer",
                    tone: .review
                ) {
                    ReviewSettingsView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Card Rendering",
                    systemImage: "textformat",
                    tone: .accent
                ) {
                    CardRenderingSettingsView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Manage Templates",
                    systemImage: "doc.text",
                    tone: .learning
                ) {
                    DeckTemplateListView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Template Overrides",
                    systemImage: "arrow.turn.down.right",
                    tone: .neutral
                ) {
                    TemplateOverridesView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Code Editor",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    tone: .link
                ) {
                    CodeEditorSettingsView()
                }
            }
        }
    }

    private var readerSection: some View {
        Group {
            SettingsSectionHeader(title: "Reader")
            SettingsGroup {
                SettingsRowLink(
                    title: "Dictionaries",
                    systemImage: "character.book.closed",
                    tone: .danger
                ) {
                    ReaderDictionarySettingsView()
                }
            }
        }
    }

    private var maintenanceSection: some View {
        Group {
            SettingsSectionHeader(title: "Maintenance")
            SettingsGroup {
                SettingsRowLink(
                    title: "Manage Tags",
                    systemImage: "tag",
                    tone: .neutral
                ) {
                    TagsView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Database",
                    systemImage: "internaldrive",
                    tone: .info
                ) {
                    MaintenanceView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Empty Cards",
                    systemImage: "square.dashed",
                    tone: .danger
                ) {
                    EmptyCardsView()
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Backups",
                    systemImage: "clock.arrow.circlepath",
                    tone: .mature
                ) {
                    BackupView(username: AccountStore.shared.current.displayName)
                }
                SettingsSeparator()
                SettingsRowLink(
                    title: "Media Check",
                    systemImage: "photo",
                    tone: .learning
                ) {
                    MediaCheckResultView()
                }
            }
        }
    }

    private var aboutSection: some View {
        Group {
            SettingsSectionHeader(title: "About")
            SettingsGroup {
                SettingsRowLink(
                    title: "About Amgi",
                    systemImage: "info.circle",
                    tone: .accent,
                    detail: appVersion
                ) {
                    AboutView()
                }
            }
        }
    }

    private var footer: some View {
        Text("Amgi · v\(appVersion) · Built with care")
            .amgiFont(.micro)
            .foregroundStyle(palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)
            .padding(.bottom, AmgiSpacing.sm)
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

#if DEBUG

#Preview {
    NavigationStack {
        SettingsView(onSwitchProfile: { _ in })
    }
}
#endif
