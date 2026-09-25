public import SwiftUI
import AmgiTheme

/// Library-hero card: `surfaceElevated` fill, eyebrow + big numeral +
/// subtitle stacked on the left, optional decoration (streak badge)
/// trailing, optional footer (CTA), optional sidecar (sparkline).
/// Type uses palette text roles; accent belongs on the CTA, not the field.
///
/// Compact: header, footer, sidecar stacked (iPhone). Regular: the
/// same header + CTA column at iPhone content width, sidecar beside
/// it. Height is the column's ideal size so a List cannot stretch it.
///
/// Built on `AmgiCard` with the same chrome as `DeckDetailTile`
/// (`shadows.sm`, `AmgiRadius.hero`). Other surfaces compose `AmgiCard`
/// directly rather than extend this variant.
public struct AmgiHeroSummary<Decoration: View, Footer: View, Sidecar: View>: View {
    public let eyebrow: String?
    public let bigNumber: String
    public let subtitle: String?
    public let background: AmgiCardBackground
    @ViewBuilder public let decoration: () -> Decoration
    @ViewBuilder public let footer: () -> Footer
    @ViewBuilder public let sidecar: () -> Sidecar

    @Environment(\.palette) private var palette

    public init(
        eyebrow: String?,
        bigNumber: String,
        subtitle: String?,
        background: AmgiCardBackground = .surfaceElevated,
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
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.hero
        ) {
            AdaptiveHeroLayout {
                compactColumn
                sidecar()
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
                    .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                    .foregroundStyle(palette.textTertiary)
            }
            Text(bigNumber)
                .amgiFont(size: 56, weight: .bold, tracking: -1.2, relativeTo: .largeTitle)
                .foregroundStyle(palette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .amgiFont(size: 15, weight: .regular, relativeTo: .subheadline)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .layoutPriority(1)
    }
}

/// Content width of the iPhone hero column (card minus AmgiCard insets).
enum LibraryHeroMetrics {
    static let compactColumnWidth: CGFloat = 320
    static let compactSparklineHeight: CGFloat = 64
}

/// Places the Library hero side-by-side only when the card itself has
/// enough room for both pieces. The old regular-width branch used a fixed
/// 320-point column, which could clip the copy and squeeze the sparkline in
/// an iPad split pane. This layout makes the decision from the actual card
/// proposal and keeps the compact vertical composition below 420 points.
private struct AdaptiveHeroLayout: Layout {
    let spacing: CGFloat = 20
    let minimumHorizontalWidth: CGFloat = 420

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? minimumHorizontalWidth
        let views = Array(subviews)
        guard views.count == 2 else {
            return views[0].sizeThatFits(proposal)
        }

        if width < minimumHorizontalWidth {
            let first = views[0].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            let second = views[1].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            return CGSize(width: width, height: first.height + spacing + second.height)
        }

        let columnWidth = min(
            LibraryHeroMetrics.compactColumnWidth,
            max(220, (width - spacing) * 0.58)
        )
        let sidecarWidth = max(100, width - columnWidth - spacing)
        let first = views[0].sizeThatFits(
            ProposedViewSize(width: columnWidth, height: nil)
        )
        let second = views[1].sizeThatFits(
            ProposedViewSize(width: sidecarWidth, height: nil)
        )
        return CGSize(width: width, height: max(first.height, second.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let views = Array(subviews)
        guard views.count == 2 else {
            views[0].place(at: bounds.origin, proposal: proposal)
            return
        }

        let width = bounds.width
        if width < minimumHorizontalWidth {
            let first = views[0].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            views[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: first.height)
            )
            views[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + first.height + spacing),
                proposal: ProposedViewSize(width: width, height: bounds.height - first.height - spacing)
            )
            return
        }

        let columnWidth = min(
            LibraryHeroMetrics.compactColumnWidth,
            max(220, (width - spacing) * 0.58)
        )
        let sidecarX = bounds.minX + columnWidth + spacing
        let sidecarWidth = max(100, bounds.maxX - sidecarX)
        views[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
        )
        views[1].place(
            at: CGPoint(x: sidecarX, y: bounds.minY),
            proposal: ProposedViewSize(width: sidecarWidth, height: bounds.height)
        )
    }
}

public extension AmgiHeroSummary where Sidecar == EmptyView {
    init(
        eyebrow: String?,
        bigNumber: String,
        subtitle: String?,
        background: AmgiCardBackground = .surfaceElevated,
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
