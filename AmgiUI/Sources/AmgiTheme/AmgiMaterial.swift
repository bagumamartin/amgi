public import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Translucency weight for floating chrome. Maps to a SwiftUI `Material`,
/// but routed through `amgiMaterial(_:in:)` so the Reduce Transparency
/// fallback is decided once instead of per call site.
public enum AmgiMaterialWeight: Sendable {
    /// Lightest — small chips and pills laid over content.
    case light
    /// Default weight for floating controls (circular buttons, capsules).
    case regular

    var material: Material {
        switch self {
        case .light:   .ultraThinMaterial
        case .regular: .regularMaterial
        }
    }
}

public extension View {
    /// Backs a floating surface with a translucent material, falling back to
    /// an opaque palette surface when the user has asked for reduced
    /// transparency.
    ///
    /// A blurred material over arbitrary book or card content is exactly the
    /// case Reduce Transparency exists for — legibility there depends on the
    /// content underneath, which we don't control. The fallback keeps the
    /// same shape and elevation and only drops the blur.
    func amgiMaterial<S: Shape>(_ weight: AmgiMaterialWeight, in shape: S) -> some View {
        modifier(AmgiMaterialModifier(weight: weight, shape: shape))
    }
}

private struct AmgiMaterialModifier<S: Shape>: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let weight: AmgiMaterialWeight
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(palette.surfaceElevated, in: shape)
        } else {
            content.background(weight.material, in: shape)
        }
    }
}
