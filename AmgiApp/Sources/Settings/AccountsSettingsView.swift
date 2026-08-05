import SwiftUI
import AmgiTheme

/// Profile picker / manager. Each row is one `AmgiAccount`; the active
/// row shows a checkmark, tapping any other switches immediately. Add
/// via `+`, swipe to delete (with optional "delete files" prompt).
struct AccountsSettingsView: View {
    @State private var store = AccountStore.shared
    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var addError: String?
    @State private var pendingDelete: AmgiAccount?
    @State private var deleteError: String?

    @Environment(\.palette) private var palette

    // Stays a `List` rather than moving to `SettingsPage`: profile rows carry
    // `swipeActions`, which only exist inside a List. The design chrome
    // (palette background, elevated row surfaces, tinted tiles) is applied
    // to the List instead, so it reads like the rest of Settings without
    // losing swipe-to-delete.
    var body: some View {
        List {
            profilesSection
            addSection
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSheet) {
            addProfileSheet
        }
        .alert(
            "Delete \(pendingDelete?.displayName ?? "")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { account in
            Button("Delete profile only", role: .destructive) {
                attemptDelete(account, deleteFiles: false)
            }
            Button("Delete profile and files", role: .destructive) {
                attemptDelete(account, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Files include the Anki collection, media, and per-profile sync state. Deleting only the profile leaves the files on disk; you can re-add the profile to recover.")
        }
        .alert(
            "Couldn't delete profile",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var profilesSection: some View {
        Section {
            ForEach(store.accounts) { account in
                profileRow(account)
                    .listRowBackground(palette.surfaceElevated)
            }
        } header: {
            SettingsListHeader("Profiles")
        }
    }

    private var addSection: some View {
        Section {
            Button {
                newName = ""
                addError = nil
                showAddSheet = true
            } label: {
                HStack(spacing: AmgiSpacing.md) {
                    SettingsIconTile(systemImage: "plus", tone: .accent)
                    Text("New profile")
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .listRowBackground(palette.surfaceElevated)
        } footer: {
            Text("Each profile keeps its own collection, sync login, and review history. Switching applies immediately.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var addProfileSheet: some View {
        NavigationStack {
            SettingsPage {
                SettingsSectionHeader(title: "Name")
                SettingsGroup {
                    TextField(
                        "Profile name",
                        text: $newName,
                        prompt: Text("e.g. Korean").foregroundStyle(palette.textTertiary)
                    )
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                        .labelsHidden()
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, AmgiSpacing.lg)
                        .padding(.vertical, AmgiSpacing.md)
                        .frame(minHeight: 44)
                }
                if let addError {
                    SettingsFootnote(addError)
                        .foregroundStyle(palette.danger)
                }
            }
            .navigationTitle("New profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { attemptAdd() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

}

private extension AccountsSettingsView {
    @ViewBuilder
    func profileRow(_ account: AmgiAccount) -> some View {
        Button {
            guard account.id != store.selectedID else { return }
            Task { await switchProfile(to: account) }
        } label: {
            HStack(spacing: AmgiSpacing.md) {
                ProfileMonogram(name: account.displayName)
                VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
                    Text(account.displayName)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                    Text("Created \(account.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: AmgiSpacing.sm)
                if account.id == store.selectedID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = account
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(account.id == store.selectedID || store.accounts.count <= 1)
        }
    }

    func attemptAdd() {
        do {
            _ = try store.add(displayName: newName)
            showAddSheet = false
        } catch {
            addError = error.localizedDescription
        }
    }

    func attemptDelete(_ account: AmgiAccount, deleteFiles: Bool) {
        do {
            try store.remove(account, deleteFiles: deleteFiles)
        } catch {
            deleteError = error.localizedDescription
        }
        pendingDelete = nil
    }
}

// MARK: - Monogram

/// The design's gradient profile avatar, at row scale. Uses the same
/// accent→link ramp as the mock's `linear-gradient(135deg,#0a84ff,#5e5ce6)`,
/// resolved from the palette so it follows the active theme.
private struct ProfileMonogram: View {
    @Environment(\.palette) private var palette

    let name: String

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        Text(initial)
            .amgiFont(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                LinearGradient(
                    colors: [palette.accent, palette.link],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
    }
}

// MARK: - Preview

#Preview {
    NavigationStack { AccountsSettingsView() }
}
