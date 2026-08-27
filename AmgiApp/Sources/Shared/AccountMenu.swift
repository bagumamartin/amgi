// AmgiApp/Sources/Shared/AccountMenu.swift
import SwiftUI

/// Destinations the account menu can push onto a root stack. Both reuse
/// the existing Settings feature views; manageProfiles skips straight to
/// profile management.
enum AccountMenuDestination: Hashable {
    case settings
    case manageProfiles
}

/// The account/profile affordance for every ROOT screen — replaces a
/// Settings tab per browse-redesign-spec D2. Menu-bar Settings on macOS /
/// iPadOS 26+ stays canonical there; this menu is additionally available
/// everywhere, so placement stays uniform across platforms.
struct AccountMenuModifier: ViewModifier {
    let placement: ToolbarItemPlacement

    @State private var destination: AccountMenuDestination?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: placement) {
                    ProfilePickerMenu(open: $destination)
                }
            }
            // Destination state lives with the stack; menu rows set it,
            // dismissal clears it.
            .navigationDestination(isPresented: Binding(
                get: { destination != nil },
                set: { if !$0 { destination = nil } }
            )) {
                Group {
                    switch destination ?? .settings {
                    case .settings: SettingsView()
                    case .manageProfiles: AccountsSettingsView()
                    }
                }
            }
    }
}

extension View {
    /// Installs the profile/account toolbar control plus its push
    /// destinations. Use once per root view, inside its NavigationStack.
    func accountMenu(placement: ToolbarItemPlacement = .topBarLeading) -> some View {
        modifier(AccountMenuModifier(placement: placement))
    }

    /// Registers settings/manage-profiles push destinations for an
    /// `AccountMenuButton` placed outside a toolbar (Study's custom
    /// header on iOS). Apply where a NavigationStack exists.
    func accountMenuDestinations(_ destination: Binding<AccountMenuDestination?>) -> some View {
        modifier(AccountMenuDestinationModifier(destination: destination))
    }
}

private struct AccountMenuDestinationModifier: ViewModifier {
    @Binding var destination: AccountMenuDestination?

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: Binding(
                get: { destination != nil },
                set: { if !$0 { destination = nil } }
            )) {
                Group {
                    switch destination ?? .settings {
                    case .settings: SettingsView()
                    case .manageProfiles: AccountsSettingsView()
                    }
                }
            }
    }
}
