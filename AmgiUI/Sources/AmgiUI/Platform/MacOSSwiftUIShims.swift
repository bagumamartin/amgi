public import SwiftUI

// macOS shims for iOS-only SwiftUI API. Feature views were written iOS-first
// and lean on modifiers with no macOS counterpart (nav-bar title modes,
// keyboard traits, full-screen covers, top/bottom-bar toolbar placements).
// Rather than #if-guarding ~100 call sites, the macOS build resolves the
// same spellings against no-op (or sheet-fallback) stand-ins declared here.
// Scoped to #if os(macOS) so iOS keeps using the real API.
#if os(macOS)

public enum AmgiNavigationBarTitleDisplayMode {
    case automatic, inline, large
}

public enum AmgiTextInputAutocapitalization {
    case never, words, sentences, characters
}

public enum AmgiKeyboardType {
    case `default`, URL, emailAddress, numberPad, decimalPad, asciiCapable
}

extension View {
    public func navigationBarTitleDisplayMode(
        _ mode: AmgiNavigationBarTitleDisplayMode
    ) -> some View {
        self
    }

    public func textInputAutocapitalization(
        _ autocapitalization: AmgiTextInputAutocapitalization
    ) -> some View {
        self
    }

    public func keyboardType(_ type: AmgiKeyboardType) -> some View {
        self
    }

    public func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    public func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
}

extension ToolbarItemPlacement {
    public static var topBarLeading: ToolbarItemPlacement { .navigation }
    public static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    public static var bottomBar: ToolbarItemPlacement { .status }
}

public enum AmgiNavigationBarDrawerDisplayMode {
    case automatic, always
}

extension SearchFieldPlacement {
    public static func navigationBarDrawer(
        displayMode: AmgiNavigationBarDrawerDisplayMode
    ) -> SearchFieldPlacement {
        .toolbar
    }
}

#endif
