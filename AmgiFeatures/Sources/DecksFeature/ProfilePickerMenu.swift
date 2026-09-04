import SwiftUI
import AmgiTheme
import AmgiAppCore
import AmgiAppShared

/// Compact toolbar menu: switch profile immediately, and open Settings /
/// Manage Profiles on the enclosing stack via `.accountMenu()`.
///
/// `onSwitch` is injected from the composition root — it closes/reopens the
/// collection — so this view does not import that machinery.
package struct ProfilePickerMenu: View {
    let onSwitch: (AmgiAccount) async -> Void
    @Binding var open: AccountMenuDestination?

    @State private var store = AccountStore.shared
    @State private var iconStore = ProfileIconStore.shared
    @Environment(\.palette) private var palette

    init(
        onSwitch: @escaping (AmgiAccount) async -> Void,
        open: Binding<AccountMenuDestination?>
    ) {
        self.onSwitch = onSwitch
        self._open = open
    }

    var body: some View {
        Menu {
            Section {
                ForEach(store.accounts) { account in
                    Button {
                        Task { await onSwitch(account) }
                    } label: {
                        HStack {
                            if let emoji = iconStore.icon(for: account.id) {
                                Text(emoji)
                            }
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
            Section {
                Button("Settings…", systemImage: "gearshape") {
                    open = .settings
                }
                Button("Manage Profiles…", systemImage: "person.crop.rectangle.stack") {
                    open = .manageProfiles
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let emoji = iconStore.icon(for: store.current.id) {
                    Text(emoji)
                        .font(.system(size: 18))
                } else {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(palette.accent)
                }
                Text(store.current.displayName)
                    .amgiFont(.bodyEmphasis)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Profile and settings: \(store.current.displayName)")
        .task { await iconStore.refresh() }
    }
}
