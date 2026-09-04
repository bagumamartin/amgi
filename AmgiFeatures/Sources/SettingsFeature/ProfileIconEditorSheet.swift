import SwiftUI
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AnkiClients
import Dependencies
#if os(iOS)
// Vendored iOS-only static library (see Vendor/MCEmojiPicker/VENDOR_NOTE.md).
import MCEmojiPicker
#endif

/// Editor for a profile's emoji icon. iOS uses MCEmojiPicker; macOS has no
/// system emoji-picker view, so it takes a validated single-emoji field.
/// Commits write through `ProfileIconStore` (col.conf → collection sync)
/// and bump the generation so the Library switcher updates immediately.
struct ProfileIconEditorSheet: View {
    let account: AmgiAccount
    let onDone: () -> Void

    @Dependency(\.collectionStore) private var store
    @State private var iconStore = ProfileIconStore.shared
    @State private var showPicker = false
    @State private var draftText = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    HStack(spacing: 12) {
                        avatarPreview
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            Text(iconStore.icon(for: account.id) == nil
                                 ? "Default icon"
                                 : "Emoji icon")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                }
                pickerSection
                Section {
                    if iconStore.icon(for: account.id) != nil {
                        Button(role: .destructive) {
                            Task { await commit(nil) }
                        } label: {
                            Label("Use Default Icon", systemImage: "arrow.uturn.backward")
                        }
                    }
                } footer: {
                    #if os(macOS)
                    Text("Paste any emoji — e.g. 🙂 📚 🇰🇷 — then Save.")
                    #endif
                }
            }
            .navigationTitle("Profile Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .presentationSizing(.fitted)
        #endif
    }

    // MARK: - Sections

    private var avatarPreview: some View {
        Group {
            if let emoji = iconStore.icon(for: account.id) {
                Text(emoji).font(.system(size: 30))
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var pickerSection: some View {
        #if os(iOS)
        Section {
            Button {
                showPicker.toggle()
            } label: {
                HStack {
                    Text("Choose Emoji")
                    Spacer()
                    if let current = iconStore.icon(for: account.id) {
                        Text(current).amgiFont(.cardTitle)
                    } else {
                        Image(systemName: "face.smiling")
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
        .emojiPicker(
            isPresented: $showPicker,
            // Wrapper takes a non-optional String; empty writes (dismissal)
            // are ignored.
            selectedEmoji: Binding(
                get: { iconStore.icon(for: account.id) ?? "" },
                set: { newValue in
                    guard !newValue.isEmpty else { return }
                    Task { await commit(newValue) }
                }
            )
        )
        #else
        Section {
            TextField("🙂", text: $draftText)
                .autocorrectionDisabled()
            Button("Save Emoji") {
                Task { await commit(ProfileIconStore.sanitizedEmoji(from: draftText)) }
            }
            .disabled(ProfileIconStore.sanitizedEmoji(from: draftText) == nil)
        }
        #endif
    }

    // MARK: - Commit

    private func commit(_ emoji: String?) async {
        await iconStore.set(emoji, for: account.id)
        // Generation bump refreshes every screen showing the switcher;
        // `.localUser` queues the automatic sync so the blob propagates.
        store.invalidateAll(origin: .localUser)
        dismiss()
        onDone()
    }
}
