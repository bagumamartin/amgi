public import SwiftUI

/// Shared tactile press feedback for buttons that opt out of the system
/// highlight via `.buttonStyle(.plain)`.
public struct PressScaleButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == PressScaleButtonStyle {
    static var pressScale: PressScaleButtonStyle { PressScaleButtonStyle() }
}
