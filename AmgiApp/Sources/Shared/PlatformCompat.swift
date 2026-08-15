import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// macOS shims for iOS-only SwiftUI API. The app's view code was written
// iOS-first and leans on modifiers with no macOS counterpart (nav-bar title
// modes, keyboard traits, full-screen covers, top/bottom-bar toolbar
// placements). Rather than #if-guarding ~100 call sites, the macOS build
// resolves the same spellings against no-op (or sheet-fallback) stand-ins
// declared here. Each shim is scoped to #if os(macOS) so iOS keeps using the
// real API; if Apple ever ships a native equivalent the shim for it can be
// deleted without touching call sites.
#if os(macOS)

// MARK: - Stand-in option enums

enum AmgiNavigationBarTitleDisplayMode {
    case automatic, inline, large
}

enum AmgiTextInputAutocapitalization {
    case never, words, sentences, characters
}

enum AmgiKeyboardType {
    case `default`, URL, emailAddress, numberPad, decimalPad, asciiCapable
}

// NB: `navigationBarBackButtonHidden` and `presentationDragIndicator` look
// iOS-only but are declared (as inert no-ops) in the macOS SwiftUI SDK too,
// so they need no shim — shimming them actually causes ambiguity errors.

// MARK: - No-op view modifiers

extension View {
    func navigationBarTitleDisplayMode(
        _ mode: AmgiNavigationBarTitleDisplayMode
    ) -> some View {
        self
    }

    func textInputAutocapitalization(
        _ autocapitalization: AmgiTextInputAutocapitalization
    ) -> some View {
        self
    }

    func keyboardType(_ type: AmgiKeyboardType) -> some View {
        self
    }
}

// MARK: - fullScreenCover → sheet fallback

extension View {
    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
}

// MARK: - Toolbar placement mapping

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var bottomBar: ToolbarItemPlacement { .status }
}

// NB: `.toolbar(.hidden, for: .navigationBar/.tabBar)` has no harmless macOS
// analogue (hiding `.windowToolbar` would drop back buttons and Cancel/Save
// items), so those call sites are guarded with `#if os(iOS)` instead of a
// shim. Same for `.toolbarBackground/.toolbarColorScheme(for: .navigationBar)`.

// MARK: - Search placement mapping

enum AmgiNavigationBarDrawerDisplayMode {
    case automatic, always
}

extension SearchFieldPlacement {
    static func navigationBarDrawer(
        displayMode: AmgiNavigationBarDrawerDisplayMode
    ) -> SearchFieldPlacement {
        .toolbar
    }
}

// MARK: - Platform colour/image aliases

typealias PlatformColor = NSColor
typealias PlatformImage = NSImage

extension Color {
    init(platformColor: NSColor) {
        self.init(nsColor: platformColor)
    }
}

extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}

#else

// MARK: - Platform colour/image aliases (iOS)

typealias PlatformColor = UIColor
typealias PlatformImage = UIImage

extension Color {
    init(platformColor: UIColor) {
        self.init(uiColor: platformColor)
    }
}

extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}

#endif
