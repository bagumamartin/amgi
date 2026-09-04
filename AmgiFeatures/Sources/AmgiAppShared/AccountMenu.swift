public import SwiftUI

/// Destinations the account menu can push onto a root stack.
public enum AccountMenuDestination: Hashable, Sendable {
    case settings
    case manageProfiles
}

/// Supplies the account/profile toolbar control and its push destinations
/// to features that must not import `SettingsFeature` or `DecksFeature`.
///
/// Same inversion as `LookupPopupProviding`: zero stored properties on the
/// conformer so SwiftUI does not invalidate every reader on each root body
/// evaluation. The app root (`RootFeature`) is the only conformer.
@MainActor
public protocol AccountMenuProviding {
    func menu(open: Binding<AccountMenuDestination?>) -> AnyView
    func destination(for: AccountMenuDestination) -> AnyView
}

public extension EnvironmentValues {
    /// `nil` means no provider (previews / tests): the modifier is a no-op.
    @Entry var accountMenuProvider: (any AccountMenuProviding)? = nil
}

/// The account/profile affordance for every ROOT screen — replaces a
/// Settings tab. The root injects the real picker and Settings screens.
struct AccountMenuModifier: ViewModifier {
    let placement: ToolbarItemPlacement
    @Environment(\.accountMenuProvider) private var provider
    @State private var destination: AccountMenuDestination?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if let provider {
                    ToolbarItem(placement: placement) {
                        provider.menu(open: $destination)
                    }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { destination != nil },
                set: { if !$0 { destination = nil } }
            )) {
                if let provider {
                    provider.destination(for: destination ?? .settings)
                }
            }
    }
}

package extension View {
    /// Installs the profile/account toolbar control plus its push
    /// destinations. Use once per root view, inside its NavigationStack.
    package func accountMenu(placement: ToolbarItemPlacement = .topBarLeading) -> some View {
        modifier(AccountMenuModifier(placement: placement))
    }

    package func accountMenuDestinations(_ destination: Binding<AccountMenuDestination?>) -> some View {
        modifier(AccountMenuDestinationModifier(destination: destination))
    }
}

private struct AccountMenuDestinationModifier: ViewModifier {
    @Binding var destination: AccountMenuDestination?
    @Environment(\.accountMenuProvider) private var provider

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: Binding(
                get: { destination != nil },
                set: { if !$0 { destination = nil } }
            )) {
                if let provider {
                    provider.destination(for: destination ?? .settings)
                }
            }
    }
}
