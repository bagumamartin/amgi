import SwiftUI
import AmgiEmbeddings
import AmgiTheme

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
        Form {
            Section {
                Button("Check Database") { model.checkDatabase() }
            } footer: {
                Text("Verifies the integrity of your local collection.")
            }

            Section {
                ModelAssetStatusView()
                Picker("Download over", selection: $modelPolicyRaw) {
                    ForEach(ModelDownloadPreferences.Policy.allCases) { policy in
                        Text(policy.rawValue).tag(policy.rawValue)
                    }
                }
                Button("Delete AI Model", role: .destructive) {
                    showModelDeleteConfirm = true
                }
                .disabled(!ModelAssetManager.isModelInstalled)
            } header: {
                Text("AI Model")
            } footer: {
                Text("Powers smarter deck icons and meaning-based search. Updates download automatically within this network setting.")
            }

            Section {
                Button("Reset Everything", role: .destructive) {
                    showResetConfirm = true
                }
            } footer: {
                Text("Deletes the local collection and credentials. You will need to sync or re-import after.")
            }

            if !model.statusMessage.isEmpty {
                Section("Status") {
                    Text(model.statusMessage)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
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
