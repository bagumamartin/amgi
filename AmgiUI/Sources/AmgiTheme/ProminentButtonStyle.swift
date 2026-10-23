public import SwiftUI

public extension View {
    /// `.borderedProminent` with its label in `palette.onAccent`. The system
    /// style always draws a white label, which is unreadable on the light
    /// violet the dark schemes use as `accent`. Only for accent-tinted
    /// buttons — a destructive or custom-tinted one keeps the plain style.
    func amgiProminentButtonStyle() -> some View {
        modifier(ProminentButtonModifier())
    }
}

private struct ProminentButtonModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        #if os(macOS)
        // AppKit's bordered-prominent bezel ignores `foregroundStyle` and
        // keeps its white label, so the Mac draws the fill itself.
        content.buttonStyle(MacProminentButtonStyle())
        #else
        content
            .buttonStyle(.borderedProminent)
            .foregroundStyle(palette.onAccent)
        #endif
    }
}

#if os(macOS)
private struct MacProminentButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, controlSize == .small ? 8 : 12)
            .padding(.vertical, verticalPadding)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: 3
        case .large, .extraLarge: 8
        default: 5
        }
    }
}
#endif
