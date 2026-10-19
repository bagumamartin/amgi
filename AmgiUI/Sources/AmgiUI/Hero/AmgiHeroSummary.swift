public import SwiftUI
import AmgiTheme

/// Library-hero card: `surfaceElevated` fill. The header holds the main
/// content (for the Library hero: due numeral + streak beside the stat
/// tiles); the optional footer band sits under it; the sidecar holds the
/// sparkline.
/// Type uses palette text roles; accent belongs on data, not the field.
///
/// Compact: header, band, sidecar stacked (iPhone). Regular: the same
/// header + band column at iPhone content width with the sidecar beside
/// it. Height is the column's ideal size so a List cannot stretch it.
///
/// Built on `AmgiCard` with the same chrome as `DeckDetailTile`
/// (`shadows.sm`, `AmgiRadius.hero`). Other surfaces compose `AmgiCard`
/// directly rather than extend this variant.
public struct AmgiHeroSummary<Header: View, Footer: View, Sidecar: View>: View {
    public let background: AmgiCardBackground
    @ViewBuilder public let header: () -> Header
    @ViewBuilder public let footer: () -> Footer
    @ViewBuilder public let sidecar: () -> Sidecar

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        background: AmgiCardBackground = .surfaceElevated,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder footer: @escaping () -> Footer,
        @ViewBuilder sidecar: @escaping () -> Sidecar
    ) {
        self.background = background
        self.header = header
        self.footer = footer
        self.sidecar = sidecar
    }

    public var body: some View {
        AmgiCard(
            background: background,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.hero
        ) {
            if horizontalSizeClass == .regular {
                RegularHeroSplit {
                    column
                    sidecar()
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    column
                    sidecar()
                }
            }
        }
    }

    /// Header plus footer band. Used as-is on compact and as the left
    /// column on regular.
    private var column: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
            footer()
        }
    }
}

/// Content width of the iPhone hero column (card minus AmgiCard insets).
enum LibraryHeroMetrics {
    static let compactColumnWidth: CGFloat = 320
    static let compactSparklineHeight: CGFloat = 64
    /// Card width at which the Today pane's hero puts its four tiles in a row.
    static let minimumWidePaneWidth: CGFloat = 600
    static let paneSparklineMinHeight: CGFloat = 72
}

/// Places the iPhone column at a fixed compact width and the sidecar
/// in the remaining space. `sizeThatFits` reports the column's ideal
/// height (ignoring a tall List proposal) so the card cannot stretch.
private struct RegularHeroSplit: Layout {
    var spacing: CGFloat = 20

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let columnWidth = LibraryHeroMetrics.compactColumnWidth
        let left = subviews[0].sizeThatFits(
            ProposedViewSize(width: columnWidth, height: nil)
        )
        let width = proposal.width ?? (columnWidth + spacing + 120)
        return CGSize(width: width, height: left.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let columnWidth = LibraryHeroMetrics.compactColumnWidth
        let height = bounds.height
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: columnWidth, height: height)
        )
        guard subviews.count > 1 else { return }
        let sidecarX = bounds.minX + columnWidth + spacing
        let sidecarWidth = max(0, bounds.maxX - sidecarX)
        subviews[1].place(
            at: CGPoint(x: sidecarX, y: bounds.minY),
            proposal: ProposedViewSize(width: sidecarWidth, height: height)
        )
    }
}
