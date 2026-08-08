import SwiftUI
import AmgiTheme
import AmgiAppCore

/// Compact toolbar menu that exposes profile switching from the Decks
/// tab without forcing the user into Settings. Active profile shows a
/// checkmark; tapping any other profile switches immediately — the
/// collection is swapped in place and the UI rebuilds.
///
/// Add/delete still happens in Settings → Account → Profiles; this
/// menu is a fast picker, not a full manager.
struct ProfilePickerMenu: View {
    @State private var store = AccountStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            Section {
                ForEach(store.accounts) { account in
                    Button {
                        Task { await switchProfile(to: account) }
                    } label: {
                        HStack {
                            Text(account.displayName)
                            if account.id == store.selectedID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } header: {
                Text("Switch profile")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(palette.accent)
                Text(store.current.displayName)
                    .amgiFont(.bodyEmphasis)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Profile: \(store.current.displayName)")
    }
}
