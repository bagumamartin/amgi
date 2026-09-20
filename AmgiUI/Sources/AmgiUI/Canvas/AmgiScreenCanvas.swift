public import SwiftUI
import AmgiTheme

/// Quiet page canvas — a slight lift at the top that falls off toward
/// the page color below. Hue stays on `palette.background`; cards stay
/// on `surfaceElevated`. This is only the page.
///
/// `MeshGradient` lives here, not at call sites, so feature screens cannot
/// spell a raw mesh (same reason chrome cannot spell a raw `.glassEffect(`).
public struct AmgiScreenCanvas: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
        #if os(watchOS)
        palette.background
        #else
        ZStack {
            palette.background
            if !reduceTransparency {
                mesh
            }
        }
        #endif
    }

    #if !os(watchOS)
    private var mesh: MeshGradient {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.50, 0.0], [1.0, 0.0],
                [0.0, 0.42], [0.55, 0.48], [1.0, 0.40],
                [0.0, 1.0], [0.50, 1.0], [1.0, 1.0],
            ],
            colors: [
                bright, bright, bright,
                surface, surface, surface,
                base, base, base,
            ]
        )
    }

    private var base: Color { palette.background }

    /// Brighter top — hero sits on a slightly lifted field.
    private var bright: Color {
        palette.background.mix(with: palette.surfaceElevated, by: 0.55, in: .perceptual)
    }

    /// Neutral rest of the page.
    private var surface: Color {
        palette.background.mix(with: palette.surface, by: 0.32, in: .perceptual)
    }
    #endif
}

public extension View {
    /// Paints ``AmgiScreenCanvas`` behind the view, ignoring safe areas so
    /// the wash runs under the nav bar and tab bar.
    func amgiScreenCanvas() -> some View {
        background {
            AmgiScreenCanvas()
                .ignoresSafeArea()
        }
    }
}

#if DEBUG && !os(watchOS)
#Preview("Light") {
    Text("Canvas")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .amgiScreenCanvas()
        .environment(\.palette, .vividLight)
}

#Preview("Dark") {
    Text("Canvas")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .amgiScreenCanvas()
        .environment(\.palette, .vividDark)
        .preferredColorScheme(.dark)
}
#endif
