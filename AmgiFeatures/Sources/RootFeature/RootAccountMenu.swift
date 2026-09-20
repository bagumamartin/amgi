import AmgiAppCore
import AmgiAppShared
import DecksFeature
import SettingsFeature
import SwiftUI

/// Root-only conformer for `AccountMenuProviding`. Zero stored properties
/// so the environment value does not invalidate every toolbar on each
/// `RootView` body evaluation.
struct RootAccountMenu: AccountMenuProviding {
    func menu(open: Binding<AccountMenuDestination?>) -> AnyView {
        AnyView(
            ProfilePickerMenu(
                onSwitch: { await switchProfile(to: $0) },
                open: open
            )
        )
    }

    func sidebarFooter(open: Binding<AccountMenuDestination?>) -> AnyView {
        AnyView(AccountSidebarFooterHost(open: open))
    }

    func destination(for dest: AccountMenuDestination) -> AnyView {
        switch dest {
        case .settings:
            AnyView(SettingsView(onSwitchProfile: { await switchProfile(to: $0) }))
        case .manageProfiles:
            AnyView(AccountsSettingsView(onSwitchProfile: { await switchProfile(to: $0) }))
        }
    }
}

/// Hosts the sidebar footer. iOS writes `.settings` into `open`; macOS
/// ignores that path — Settings is a menu-bar window, not a sidebar gear.
struct AccountSidebarFooterHost: View {
    @Binding var open: AccountMenuDestination?

    var body: some View {
        AccountSidebarFooter(
            onSwitch: { await switchProfile(to: $0) },
            onOpenSettings: { open = .settings }
        )
    }
}
