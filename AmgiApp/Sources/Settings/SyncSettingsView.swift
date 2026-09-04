import SwiftUI
import AmgiTheme
import AnkiSync
import Dependencies
import Sharing

struct SyncSettingsView: View {
    @Shared(.syncMode) private var syncMode
    @Shared(.appStorage(SyncPreferences.Keys.autoSyncEnabledForCurrentUser()))
    private var autoSyncEnabled: Bool = true
    @Shared(.appStorage(SyncPreferences.Keys.autoSyncNetworkPolicyForCurrentUser()))
    private var autoSyncNetworkPolicyRaw: String = SyncPreferences.NetworkPolicy.wifiOnly.rawValue
    @Dependency(\.syncCoordinator) private var coordinator
    @State private var endpoint: String? = KeychainHelper.loadEndpoint()
    @State private var username: String? = KeychainHelper.loadUsername()
    @State private var isLoggedIn: Bool = KeychainHelper.loadHostKey() != nil
    @State private var showServerSetup = false
    @State private var showDisableConfirm = false

    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            if let endpoint {
                Section {
                    AnkiMobileAttributionView()
                }

                Section("Server") {
                    LabeledContent("URL") {
                        Text(endpoint).truncationMode(.middle).lineLimit(1)
                    }
                }

                Section("Account") {
                    LabeledContent("Username") {
                        Text(username ?? "Not signed in")
                            .foregroundStyle(username == nil ? palette.textSecondary : palette.textPrimary)
                    }
                    LabeledContent("Credentials") {
                        Text(isLoggedIn ? "Stored" : "Not signed in")
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                Section("Automatic Sync") {
                    Toggle("Sync automatically", isOn: Binding($autoSyncEnabled))
                        .onChange(of: autoSyncEnabled) { _, enabled in
                            if enabled {
                                coordinator.enableAutomaticSync()
                            } else {
                                coordinator.disableAutomaticSync()
                            }
                        }
                    Picker("Network", selection: Binding($autoSyncNetworkPolicyRaw)) {
                        ForEach(SyncPreferences.NetworkPolicy.allCases) { policy in
                            Text(policy.rawValue).tag(policy.rawValue)
                        }
                    }
                    Text("Changes sync after a short pause and periodically every 15 minutes.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }

                Section {
                    Button("Change Server") { showServerSetup = true }
                    Button("Logout", role: .destructive) { logout() }
                        .disabled(!isLoggedIn)
                }

                Section {
                    Button("Disable Sync (Local Only)", role: .destructive) {
                        showDisableConfirm = true
                    }
                } footer: {
                    Text("Stops syncing. Your local collection is unaffected.")
                }
            } else {
                Section {
                    Label("Sync is disabled", systemImage: "iphone")
                        .foregroundStyle(palette.textSecondary)
                    Button("Set Up Server") { showServerSetup = true }
                }
            }
        }
        .navigationTitle("Sync Server")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showServerSetup) {
            ServerSetupView {
                endpoint = KeychainHelper.loadEndpoint()
                username = KeychainHelper.loadUsername()
                isLoggedIn = KeychainHelper.loadHostKey() != nil
            }
        }
        .confirmationDialog(
            "Disable Sync?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Disable", role: .destructive) { disableSync() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the server, credentials, and switches the app to local-only mode.")
        }
    }

}

private extension SyncSettingsView {
    func logout() {
        coordinator.disableAutomaticSync()
        KeychainHelper.deleteHostKey()
        KeychainHelper.deleteUsername()
        username = nil
        isLoggedIn = false
    }

    func disableSync() {
        coordinator.disableAutomaticSync()
        KeychainHelper.deleteHostKey()
        KeychainHelper.deleteUsername()
        KeychainHelper.deleteEndpoint()
        $syncMode.withLock { $0 = .local }
        endpoint = nil
        username = nil
        isLoggedIn = false
    }
}

private struct ServerSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Shared(.syncMode) private var syncMode
    @State private var url: String = KeychainHelper.loadEndpoint() ?? ""
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $url, prompt: Text("https://sync.example.com"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Sync Server URL")
                } footer: {
                    Text("Enter the URL of your Anki-compatible sync server.")
                }

                Section {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 360, idealWidth: 420, maxWidth: 540)
            .presentationSizing(.fitted)
            #endif
            .navigationTitle("Sync Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private var trimmed: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ServerSetupView {
    func save() {
        var normalized = trimmed
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        try? KeychainHelper.saveEndpoint(normalized)
        $syncMode.withLock { $0 = .custom }
        UserDefaults.standard.set(true, forKey: SyncPreferences.Keys.autoSyncEnabledForCurrentUser())
        KeychainHelper.deleteHostKey()  // force re-auth on next sync
        NotificationCenter.default.post(name: .amgiSyncConfigurationChanged, object: nil)
        onSave()
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack { SyncSettingsView() }
}
