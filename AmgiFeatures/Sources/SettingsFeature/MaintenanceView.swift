import SwiftUI
import AmgiEmbeddings
import AmgiUI
import AmgiTheme
import SyncFeature

struct MaintenanceView: View {
    @State private var model = MaintenanceModel()
    @State private var showResetConfirm = false
    @State private var showModelDeleteConfirm = false
    @State private var isDeletingModel = false
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
                    tone: .info,
                    isBusy: model.isChecking
                ) {
                    guard !model.isChecking else { return }
                    Task { await model.checkDatabase() }
                }
                .disabled(model.isChecking)
            }
            SettingsFootnote("Verifies the integrity of your local Anki collection. The check can take a while on a large collection.")

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
                    isDestructive: true,
                    isBusy: isDeletingModel
                ) {
                    showModelDeleteConfirm = true
                }
                .disabled(!ModelAssetManager.isModelInstalled || model.isChecking || isDeletingModel)
            }
            .disabled(model.isChecking)
            SettingsFootnote("Powers smarter deck icons and meaning-based search. Updates download automatically within this network setting.")
            // Read so the Delete row re-evaluates on install transitions.
            .id(modelStoreGeneration)

            SettingsSectionHeader(title: "Danger Zone")
            SettingsGroup {
                SettingsButtonRow(
                    title: "Reset Everything",
                    systemImage: "trash",
                    tone: .danger,
                    isDestructive: true,
                    isBusy: model.isChecking || isDeletingModel
                ) {
                    guard !model.isChecking, !isDeletingModel else { return }
                    showResetConfirm = true
                }
                .disabled(model.isChecking || isDeletingModel)
            }
            SettingsFootnote("Deletes this profile's collection and credentials. You will need to sync or re-import after.")

            if model.isChecking {
                SettingsSectionHeader(title: "Status")
                SettingsGroup {
                    HStack(spacing: AmgiSpacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking database…")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AmgiSpacing.lg)
                    .padding(.vertical, AmgiSpacing.md)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Checking database")
                }
            } else if !model.statusMessage.isEmpty {
                SettingsSectionHeader(title: "Status")
                SettingsGroup {
                    Text(model.statusMessage)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                isDeletingModel = true
                Task {
                    defer { isDeletingModel = false }
                    try? await ModelAssetManager.shared.removeInstalledModel()
                }
            }
            .disabled(model.isChecking || isDeletingModel)
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
