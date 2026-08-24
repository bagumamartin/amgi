import SwiftUI
import AmgiTheme

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        settingsForm
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var settingsForm: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            GeometryReader { proxy in
                let inset = SettingsColumn.inset(for: proxy.size.width)
                form
                    .contentMargins(.horizontal, inset, for: .scrollContent)
            }
        } else {
            form
        }
        #else
        form
        #endif
    }

    private var form: some View {
        Form {
            Section("Appearance") {
                NavigationLink("Theme & Appearance") {
                    AppearanceSettingsView(manager: .shared)
                }
            }

            Section("Account") {
                NavigationLink("Profiles") {
                    AccountsSettingsView()
                }
                NavigationLink("Sync Server") {
                    SyncSettingsView()
                }
            }


            Section("Review") {
                NavigationLink("Review Behavior") {
                    ReviewSettingsView()
                }
                NavigationLink("Card Rendering") {
                    CardRenderingSettingsView()
                }
                NavigationLink("Shortcuts") {
                    ShortcutsSettingsView()
                }
            }

            Section("Reader") {
                NavigationLink("Reader Display") {
                    ReaderSettingsView()
                }
                NavigationLink("Dictionaries") {
                    ReaderDictionarySettingsView()
                }
            }

            Section("Tags") {
                NavigationLink("Manage Tags") {
                    TagsView()
                }
            }

            Section("Maintenance") {
                NavigationLink("Database") {
                    MaintenanceView()
                }
                NavigationLink("Backups") {
                    BackupView(username: AccountStore.shared.current.displayName)
                }
                NavigationLink("Empty Cards") {
                    EmptyCardsView()
                }
                NavigationLink("Media Check") {
                    MediaCheckResultView()
                }
            }

            Section("Card Templates") {
                NavigationLink("Manage Templates") {
                    DeckTemplateListView()
                }
                NavigationLink("Code Editor") {
                    CodeEditorSettingsView()
                }
            }

            Section {
                NavigationLink("About") {
                    AboutView()
                }
            }
        }
    }
}

private enum SettingsColumn {
    static let maxWidth: CGFloat = 800
    static func inset(for width: CGFloat) -> CGFloat {
        max(0, (width - maxWidth) / 2)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
