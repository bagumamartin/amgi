public import SwiftUI
import AmgiTheme

/// Dresses cover art as a physical book, the way Apple Books does: the art
/// keeps its own shape (never cropped, never boxed in a card), with a spine
/// crease down the leading edge, a hairline edge, near-square corners, and a
/// soft contact shadow.
///
/// Apply it to the *fitted* cover itself — before any frame that might grow
/// past the art — so the edge and shadow trace the cover, not empty space
/// around it.
public extension View {
    func bookCoverChrome(_ size: BookCoverChromeSize = .regular) -> some View {
        modifier(BookCoverChrome(size: size))
    }
}

/// Grid tiles and small list thumbnails need the same treatment at different
/// strengths: a 12pt spine and 6pt shadow overwhelm a 44pt thumbnail.
public enum BookCoverChromeSize: Sendable {
    case regular
    case compact

    fileprivate var spineWidth: CGFloat { self == .regular ? 12 : 5 }
    fileprivate var shadowRadius: CGFloat { self == .regular ? 6 : 3 }
    fileprivate var shadowY: CGFloat { self == .regular ? 4 : 2 }
}

private struct BookCoverChrome: ViewModifier {
    let size: BookCoverChromeSize

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AmgiRadius.bookCover, style: .continuous)
        content
            .overlay(alignment: .leading) { spine }
            .clipShape(shape)
            .overlay { shape.strokeBorder(edgeColor, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: size.shadowRadius, x: 0, y: size.shadowY)
    }

    /// Hinge shadow, a lifted highlight just past it, then a fade into the
    /// art — the crease a hardback's cover folds along.
    private var spine: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.22), location: 0),
                .init(color: .black.opacity(0.06), location: 0.18),
                .init(color: .white.opacity(0.18), location: 0.32),
                .init(color: .black.opacity(0.05), location: 0.55),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: size.spineWidth)
        .allowsHitTesting(false)
    }

    private var edgeColor: Color {
        colorScheme == .dark ? .white.opacity(0.2) : .black.opacity(0.12)
    }
}
