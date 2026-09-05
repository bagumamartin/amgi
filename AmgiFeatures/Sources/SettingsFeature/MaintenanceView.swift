import SwiftUI
import AmgiEmbeddings
import AmgiUI
import AmgiTheme
import SyncFeature

struct MaintenanceView: View {
    @State private var model = MaintenanceModel()
    @State private var showResetConfirm = false
    @State private var showModelDeleteConfirm = false
    /// Bumps body evaluation on install-state transitions so the Delete row
    /// tracks reality (driven by `.amgiModelAssetChanged` below).
    @State private var modelStoreGeneration = 0

    @AppStorage(ModelDownloadPreferences.policyKey)
    private var modelPolicyRaw: String = ModelDownloadPreferences.Policy.wifiOnly.rawValue

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
                    Task { await model.checkDatabase() }
                }
            }
            SettingsFootnote("Verifies the integrity of your local Anki collection.")

            SettingsSectionHeader(title: "AI Model")
            SettingsGroup {
                ModelAssetStatusView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AmgiSpacing.lg)
                    .padding(.vertical, AmgiSpacing.md)
                SettingsPickerRow(
                    title: "Download over",
                    systemImage: "arrow.down.circle",
                    tone: .info,
                    selection: $modelPolicyRaw
                ) {
                    ForEach(ModelDownloadPreferences.Policy.allCases) { policy in
                        Text(policy.rawValue).tag(policy.rawValue)
                    }
                }
                SettingsButtonRow(
                    title: "Delete AI Model",
                    systemImage: "trash",
                    tone: .danger,
                    isDestructive: true
                ) {
                    showModelDeleteConfirm = true
                }
                .disabled(!ModelAssetManager.isModelInstalled)
            }
            SettingsFootnote("Powers smarter deck icons and meaning-based search. Updates download automatically within this network setting.")
            // Read so the Delete row re-evaluates on install transitions.
            .id(modelStoreGeneration)

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
            SettingsFootnote("Deletes this profile's collection and credentials. You will need to sync or re-import after.")

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
            Button("Reset", role: .destructive) { Task { await model.resetEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the active profile's collection database, media, and stored credentials. Other profiles are unaffected. The action cannot be undone.")
        }
        .confirmationDialog(
            "Delete AI Model?",
            isPresented: $showModelDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { try? await ModelAssetManager.shared.removeInstalledModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees the on-device storage. The app keeps working with basic icon matching, and you can re-download anytime.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiModelAssetChanged)) { _ in
            modelStoreGeneration += 1
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
