public import SwiftUI
import AmgiUI
#if os(macOS)
import AppKit
#endif

/// Destinations the account menu can present.
public enum AccountMenuDestination: Hashable, Sendable, Identifiable {
    case settings
    case manageProfiles

    public var id: Self { self }
}

/// Supplies the account/profile toolbar control, sidebar footer, and
/// destinations to features that must not import `SettingsFeature` or
/// `DecksFeature`.
///
/// Same inversion as `LookupPopupProviding`: zero stored properties on the
/// conformer so SwiftUI does not invalidate every reader on each root body
/// evaluation. The app root (`RootFeature`) is the only conformer.
@MainActor
public protocol AccountMenuProviding {
    func menu(open: Binding<AccountMenuDestination?>) -> AnyView
    func sidebarFooter(open: Binding<AccountMenuDestination?>) -> AnyView
    func destination(for: AccountMenuDestination) -> AnyView
}

public extension EnvironmentValues {
    /// `nil` means no provider (previews / tests): the modifier is a no-op.
    @Entry var accountMenuProvider: (any AccountMenuProviding)? = nil
    /// `nil` uses the control's usual chrome (name on iPad/Mac, icon-only
    /// on iPhone). `false` forces the iPhone-style icon-only toolbar label.
    @Entry var accountMenuShowsName: Bool? = nil
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
            .navigationDestination(item: $destination) { dest in
                if let provider {
                    provider.destination(for: dest)
                }
            }
    }
}

/// Toolbar control only; pair with `accountMenuDestinations(_:)` on an
/// enclosing stack. Browse wraps its split view in a NavigationStack so
/// Settings covers all three columns as a normal page.
private struct AccountMenuControlModifier: ViewModifier {
    let placement: ToolbarItemPlacement
    @Binding var open: AccountMenuDestination?
    var showsName: Bool?
    @Environment(\.accountMenuProvider) private var provider

    func body(content: Content) -> some View {
        content.toolbar {
            if let provider {
                ToolbarItem(placement: placement) {
                    provider.menu(open: $open)
                        .environment(\.accountMenuShowsName, showsName)
                }
            }
        }
    }
}

private struct AccountSidebarFooterModifier: ViewModifier {
    @Binding var open: AccountMenuDestination?
    @Environment(\.accountMenuProvider) private var provider

    func body(content: Content) -> some View {
        if let provider {
            #if os(macOS)
            // safeAreaInset overlays the last sidebar rows on macOS. Pin the
            // account strip as a sibling under the list instead. Column width
            // has to live on this VStack — it is now the split-view sidebar
            // root, so a width modifier on the inner List is ignored.
            //
            // One sidebar material behind list + footer. The list's own fill
            // is cleared so the column is a single continuous surface.
            VStack(spacing: 0) {
                content
                    .scrollContentBackground(.hidden)
                provider.sidebarFooter(open: $open)
            }
            .background { MacSidebarMaterial() }
            .appSidebarWidth()
            #else
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                provider.sidebarFooter(open: $open)
            }
            #endif
        } else {
            content
        }
    }
}

package extension View {
    /// Installs the profile/account toolbar control plus its push
    /// destinations. Use once per root view, inside its NavigationStack.
    func accountMenu(placement: ToolbarItemPlacement = .topBarLeading) -> some View {
        modifier(AccountMenuModifier(placement: placement))
    }

    /// Toolbar control only; pair with `accountMenuDestinations(_:)` on an
    /// enclosing stack so Settings pushes as a normal page.
    func accountMenuControl(
        placement: ToolbarItemPlacement = .topBarLeading,
        open: Binding<AccountMenuDestination?>,
        showsName: Bool? = nil
    ) -> some View {
        modifier(AccountMenuControlModifier(
            placement: placement,
            open: open,
            showsName: showsName
        ))
    }

    /// Pins profile + Settings to the bottom of a sidebar as floating chips,
    /// like ChatGPT's Chat capsule and trailing gear.
    func accountSidebarFooter(open: Binding<AccountMenuDestination?>) -> some View {
        modifier(AccountSidebarFooterModifier(open: open))
    }

    func accountMenuDestinations(_ destination: Binding<AccountMenuDestination?>) -> some View {
        modifier(AccountMenuDestinationModifier(destination: destination))
    }
}

private struct AccountMenuDestinationModifier: ViewModifier {
    @Binding var destination: AccountMenuDestination?
    @Environment(\.accountMenuProvider) private var provider

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $destination) { dest in
                if let provider {
                    provider.destination(for: dest)
                }
            }
    }
}

#if os(macOS)
/// Matches `List` `.sidebar` fill so list + footer share one vibrancy layer.
private struct MacSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif
