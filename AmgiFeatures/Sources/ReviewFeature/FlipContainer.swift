import AmgiTheme
import SwiftUI

/// Natural (content-hugging) heights of the two native card sides, reported
/// through side-specific keys so `FlipContainer` can take the max. Measured
/// on the inner content VStack — deliberately OUTSIDE the `minHeight`
/// application point — so equalization converges instead of feeding back.
struct FrontCardNaturalHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat? = nil
    nonisolated static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

struct BackCardNaturalHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat? = nil
    nonisolated static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

/// Equalized minimum height for both sides of a native card, computed by
/// `FlipContainer` from each side's natural content height and applied via
/// the environment: without a `FlipContainer` ancestor (previews) it is nil
/// and the card hugs its content.
private struct NativeCardMinHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var nativeCardMinHeight: CGFloat? {
        get { self[NativeCardMinHeightKey.self] }
        set { self[NativeCardMinHeightKey.self] = newValue }
    }
}

/// Answer reveal for the native card surface (R12).
///
/// A 3D `rotation3DEffect` flip rasterizes SwiftUI text into an offscreen
/// texture and samples it at low effective resolution at steep angles, so the
/// answer settles in visibly blurred for ~200ms before snapping crisp. Instead
/// the two sides cross-dissolve with a small settle-in scale — vector-crisp
/// throughout, and still reads as a reveal.
///
/// Both sides are built up-front in a `ZStack` and swapped by opacity: the
/// first frame of the reveal animation must not pay for constructing and
/// laying out the back subtree inside the animation transaction (that cost
/// used to land directly on the flip). A side benefit is prefetching — image
/// blocks on both sides start loading when the card appears, not at reveal.
///
/// The card surface height is equalized to the taller side for the life of
/// the card, so the flip animates content only — no geometry jump.
///
/// Reveal (`showBack` false→true) animates; reset (→false, on advance or undo)
/// snaps instantly so a new card never plays a stale reverse animation.
///
/// Only the native path uses this; WebView cards swap sides directly, because a
/// live `WKWebView` rasterizes even worse under a transform.
struct FlipContainer<Content: View>: View {
    let showBack: Bool
    @ViewBuilder let content: (_ isBack: Bool) -> Content

    @State private var displayedBack = false
    @State private var frontNaturalHeight: CGFloat?
    @State private var backNaturalHeight: CGFloat?

    private var equalizedHeight: CGFloat? {
        let max = Swift.max(frontNaturalHeight ?? 0, backNaturalHeight ?? 0)
        return max > 0 ? max : nil
    }

    var body: some View {
        ZStack {
            side(isBack: false)
            side(isBack: true)
        }
        .onPreferenceChange(FrontCardNaturalHeightKey.self) { frontNaturalHeight = $0 }
        .onPreferenceChange(BackCardNaturalHeightKey.self) { backNaturalHeight = $0 }
        .environment(\.nativeCardMinHeight, equalizedHeight)
        .onChange(of: showBack) { _, newValue in
            if newValue {
                withAnimation(AmgiMotion.quick) { displayedBack = true }
            } else {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { displayedBack = false }
            }
        }
    }

    @ViewBuilder
    private func side(isBack: Bool) -> some View {
        content(isBack)
            .opacity(displayedBack == isBack ? 1 : 0)
            .scaleEffect(displayedBack == isBack ? 1 : 0.96)
            .allowsHitTesting(displayedBack == isBack)
            .accessibilityHidden(displayedBack != isBack)
    }
}
