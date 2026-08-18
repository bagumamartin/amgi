public import SwiftUI
import AmgiTheme

/// Library-hero card: gradient background, eyebrow + big numeral +
/// subtitle stacked on the left, optional decoration (streak badge)
/// trailing, optional footer (CTA), optional sidecar (sparkline).
/// Foreground text is white — caller picks a background that has
/// enough contrast.
///
/// Compact: header, footer, sidecar stacked (iPhone). Regular: the
/// same header + CTA column at iPhone content width, sidecar beside
/// it. Height is the column's ideal size so a List cannot stretch it.
///
/// Built on `AmgiCard` for chrome (corner + shadow + padding). Other
/// surfaces (Deck-detail tile, Stats streak) compose `AmgiCard` directly
/// rather than extend this variant.
public struct AmgiHeroSummary<Decoration: View, Footer: View, Sidecar: View>: View {
    public let eyebrow: String?
    public let bigNumber: String
    public let subtitle: String?
    public let background: AmgiCardBackground
    @ViewBuilder public let decoration: () -> Decoration
    @ViewBuilder public let footer: () -> Footer
    @ViewBuilder public let sidecar: () -> Sidecar

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        eyebrow: String?,
        bigNumber: String,
        subtitle: String?,
        background: AmgiCardBackground,
        @ViewBuilder decoration: @escaping () -> Decoration,
        @ViewBuilder footer: @escaping () -> Footer,
        @ViewBuilder sidecar: @escaping () -> Sidecar
    ) {
        self.eyebrow = eyebrow
        self.bigNumber = bigNumber
        self.subtitle = subtitle
        self.background = background
        self.decoration = decoration
        self.footer = footer
        self.sidecar = sidecar
    }

    public var body: some View {
        AmgiCard(
            background: background,
            shadow: palette.shadows.md,
            cornerRadius: AmgiRadius.card
        ) {
            if horizontalSizeClass == .regular {
                RegularHeroSplit {
                    compactColumn
                    sidecar()
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    compactColumn
                    sidecar()
                }
            }
        }
    }

    /// iPhone header + CTA: copy leading, streak trailing, full-width
    /// button. Used as-is on compact and as the left column on regular.
    private var compactColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                copyStack
                Spacer(minLength: 12)
                decoration()
            }
            footer()
        }
    }

    private var copyStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(bigNumber)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// Content width of the iPhone hero column (card minus AmgiCard insets).
enum LibraryHeroMetrics {
    static let compactColumnWidth: CGFloat = 320
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

public extension AmgiHeroSummary where Sidecar == EmptyView {
    init(
        eyebrow: String?,
        bigNumber: String,
        subtitle: String?,
        background: AmgiCardBackground,
        @ViewBuilder decoration: @escaping () -> Decoration,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.init(
            eyebrow: eyebrow,
            bigNumber: bigNumber,
            subtitle: subtitle,
            background: background,
            decoration: decoration,
            footer: footer,
            sidecar: { EmptyView() }
        )
    }
}
