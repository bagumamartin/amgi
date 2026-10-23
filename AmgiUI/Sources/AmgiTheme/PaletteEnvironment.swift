public import SwiftUI

public extension EnvironmentValues {
    @Entry var palette: Palette = .vividLight
}

public extension View {
    /// Apply at the app's root view. Reads `ThemeManager` and writes the resolved
    /// `Palette` into the environment plus applies `.preferredColorScheme(...)`
    /// when the user has overridden the system appearance, and tints system
    /// controls with the palette's `accent`.
    func themedRoot(manager: ThemeManager = .shared) -> some View {
        modifier(ThemedRootModifier(manager: manager))
    }
}

private struct ThemedRootModifier: ViewModifier {
    @Bindable var manager: ThemeManager
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let palette = manager.palette(for: systemScheme)
        return content
            .environment(\.palette, palette)
            // Without this every system control — toggles, pickers, nav back
            // buttons, alerts, text cursors — renders iOS system blue, which
            // no theme can reach. Tint with the brand accent instead; views
            // that need a semantic tint (a positive-on toggle, a swipe action)
            // still override it locally.
            .tint(palette.accent)
            .preferredColorScheme(preferredScheme)
    }

    private var preferredScheme: ColorScheme? {
        switch manager.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
