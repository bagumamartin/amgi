package import SwiftUI
import AmgiTheme
package import AmgiAppCore
package import AmgiAppShared
#if canImport(UIKit)
import UIKit
#endif

/// Toolbar profile selector. On iOS, its menu also opens Settings on the
/// enclosing stack via `.accountMenu()`. macOS uses the standard Settings entry.
///
/// `onSwitch` is injected from the composition root — it closes/reopens the
/// collection — so this view does not import that machinery.
package struct ProfilePickerMenu: View {
    let onSwitch: (AmgiAccount) async -> Void
    @Binding var open: AccountMenuDestination?

    @State private var store = AccountStore.shared
    @State private var iconStore = ProfileIconStore.shared
    @Environment(\.palette) private var palette

    package init(
        onSwitch: @escaping (AmgiAccount) async -> Void,
        open: Binding<AccountMenuDestination?>
    ) {
        self.onSwitch = onSwitch
        self._open = open
    }

    /// iPhone toolbar is icon-only; iPad/Mac keep the name beside the emoji.
    private var showsNameInLabel: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    package var body: some View {
        #if os(macOS)
        Picker("Profile", selection: Binding(
            get: { store.selectedID },
            set: { id in
                guard id != store.selectedID,
                      let account = store.accounts.first(where: { $0.id == id }) else { return }
                Task { await onSwitch(account) }
            }
        )) {
            ForEach(store.accounts) { account in
                Text(profileTitle(for: account))
                    .tag(account.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Profile: \(store.current.displayName)")
        .task { await iconStore.refresh() }
        #else
        Menu {
            Section {
                ForEach(store.accounts) { account in
                    Button {
                        Task { await onSwitch(account) }
                    } label: {
                        HStack {
                            // Native menus extract one text title per item.
                            Text(profileTitle(for: account))
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
                if showsNameInLabel {
                    Text(store.current.displayName)
                        .amgiFont(.bodyEmphasis)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityLabel("Profile and settings: \(store.current.displayName)")
        .task { await iconStore.refresh() }
        #endif
    }

    private func profileTitle(for account: AmgiAccount) -> String {
        let icon = iconStore.icon(for: account.id) ?? "👤"
        return "\(icon) \(account.displayName)"
    }
}
