import SwiftUI
import AmgiTheme

struct MaintenanceView: View {
    @State private var model = MaintenanceModel()
    @State private var showResetConfirm = false

    @Environment(\.palette) private var palette

    var body: some View {
        SettingsPage {
            SettingsSectionHeader(title: "Collection")
            SettingsGroup {
                SettingsButtonRow(
                    title: "Check Database",
                    systemImage: "stethoscope",
                    tone: .info
                ) {
                    model.checkDatabase()
                }
            }
            SettingsFootnote("Verifies the integrity of your local Anki collection.")

            SettingsSectionHeader(title: "Danger Zone")
            SettingsGroup {
                SettingsButtonRow(
                    title: "Reset Everything",
                    systemImage: "trash",
                    tone: .danger,
                    isDestructive: true
                ) {
                    showResetConfirm = true
                }
            }
            SettingsFootnote("Deletes the local collection and credentials. You will need to sync or re-import after.")

            if !model.statusMessage.isEmpty {
                SettingsSectionHeader(title: "Status")
                SettingsGroup {
                    Text(model.statusMessage)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AmgiSpacing.lg)
                        .padding(.vertical, AmgiSpacing.md)
                }
            }
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset Everything?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { model.resetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local collection database, media, and stored credentials. The action cannot be undone.")
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    NavigationStack {
        MaintenanceView()
    }
}
#endif
