public import SwiftUI

/// The one set of page metrics every scrolling screen lays out on: Library,
/// its Today pane, deck detail, Study and Stats.
///
/// The side margin is the system's own layout margin, so a page's cards
/// line up with its navigation title and with the bar above it: 20pt on
/// iPad and Mac, and on iPhone 16pt below UIKit's 414pt switch, 20pt above.
public enum AmgiPage {
    public static let compactGutter: CGFloat = 16
    public static let regularGutter: CGFloat = 20
    /// Width at which UIKit's root layout margin grows from 16 to 20.
    public static let regularGutterMinimumWidth: CGFloat = 414

    /// Vertical gap between cards and sections, and between cards side by side.
    public static let sectionSpacing: CGFloat = 20
    /// Gap between a page's columns.
    public static let columnSpacing: CGFloat = 20
    /// Space between the bar (or large title) and the first card.
    public static let topInset: CGFloat = 8
    /// Clears the floating Ask AI entry and the iPhone tab accessory.
    public static let bottomInset: CGFloat = 96
    /// Line-length cap for a single-column page that fills a whole window.
    /// Panes inside a split fill their width instead.
    public static let readableWidth: CGFloat = 820
    /// How far a page's heading travels under the bar before it is gone,
    /// for hosts that then show the title in their bar.
    public static let headingScrollThreshold: CGFloat = 36
    /// Share of that travel at which the bar takes the title over.
    static let headingAwayProgress: Double = 0.9

    public static func gutter(containerWidth: CGFloat, sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        #if os(macOS)
        return regularGutter
        #else
        if sizeClass == .regular { return regularGutter }
        return containerWidth >= regularGutterMinimumWidth ? regularGutter : compactGutter
        #endif
    }
}

/// How a page's content uses the width it is given.
public enum AmgiPageWidth: Sendable {
    /// Capped at ``AmgiPage/readableWidth`` and centred — unless the page is a
    /// pane of a split, where it fills.
    case readable
    /// Always the full width between the gutters.
    case fill
}

public extension EnvironmentValues {
    /// Set by a split's detail column. Readable pages fill a pane rather
    /// than centring a capped column inside it, so their cards line up with
    /// the pane's own bar.
    @Entry var amgiPageIsPane = false
}

public extension View {
    /// Lays a page's scroll content out on ``AmgiPage``: gutters, top and
    /// bottom insets, and the readable-width cap. Apply to the stack inside
    /// the `ScrollView`.
    func amgiPageContent(_ width: AmgiPageWidth = .readable) -> some View {
        modifier(AmgiPageContentModifier(width: width))
    }
}

private struct AmgiPageContentModifier: ViewModifier {
    let width: AmgiPageWidth

    @Environment(\.amgiPageIsPane) private var isPane
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var containerWidth: CGFloat = AmgiPage.regularGutterMinimumWidth

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: width == .readable && !isPane ? AmgiPage.readableWidth : .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AmgiPage.gutter(containerWidth: containerWidth, sizeClass: sizeClass))
            .padding(.top, AmgiPage.topInset)
            .padding(.bottom, AmgiPage.bottomInset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }
}

public extension EnvironmentValues {
    /// Set by a host that shows a page's title in its bar once the page's
    /// own heading has scrolled away (iPad Library panes). Pages opt their
    /// scroll view in with `amgiReportsHeadingScroll()`.
    @Entry var amgiOnHeadingScrolledAway: (@MainActor @Sendable (Bool) -> Void)? = nil
}

public extension View {
    /// Reports through `amgiOnHeadingScrolledAway` whether the page's
    /// heading has gone under the bar, and fades headings marked
    /// `amgiPageHeading()` as they slide under it — the way a large title
    /// leaves the page instead of showing through the bar. Apply to the
    /// page's `ScrollView`. Does nothing unless a host listens.
    func amgiReportsHeadingScroll() -> some View {
        modifier(AmgiHeadingScrollReporter())
    }

    /// Marks a page's heading: it fades out as it slides under the bar
    /// while a host shows the title there instead.
    func amgiPageHeading() -> some View {
        modifier(AmgiPageHeadingFade())
    }
}

private extension EnvironmentValues {
    /// 0 with the heading fully below the bar, 1 once it has gone under.
    @Entry var amgiHeadingUnderBarProgress: Double = 0
}

private struct AmgiHeadingScrollReporter: ViewModifier {
    @Environment(\.amgiOnHeadingScrolledAway) private var report
    @State private var progress: Double = 0

    func body(content: Content) -> some View {
        content
            .environment(\.amgiHeadingUnderBarProgress, report == nil ? 0 : progress)
            .onScrollGeometryChange(for: Double.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let travelled = Double((offset - AmgiPage.topInset) / AmgiPage.headingScrollThreshold)
                // Quantised, so a scroll updates the page twenty times per
                // heading height rather than every frame.
                let clamped: Double = min(max(travelled, 0), 1)
                return (clamped * 20).rounded() / 20
            } action: { old, new in
                guard let report else { return }
                progress = new
                let wasAway = old >= AmgiPage.headingAwayProgress
                let isAway = new >= AmgiPage.headingAwayProgress
                if wasAway != isAway { report(isAway) }
            }
    }
}

private struct AmgiPageHeadingFade: ViewModifier {
    @Environment(\.amgiHeadingUnderBarProgress) private var progress

    func body(content: Content) -> some View {
        content.opacity(1 - progress)
    }
}
