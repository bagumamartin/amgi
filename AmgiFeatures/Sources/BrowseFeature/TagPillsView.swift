import SwiftUI
import AmgiUI
import AmgiTheme

/// Hierarchy-aware tag presentation shared by the Browse list rows, the note
/// editor, and anywhere else tags surface.
///
/// A hierarchical tag (`pathophys::topiclist3`) renders as one pill with the
/// parent chain de-emphasized and the leaf emphasized, so nested tags scan
/// like breadcrumbs instead of flat noise. The full path always survives in
/// `.help` / accessibility, and truncation cuts the *parent* side first (the
/// leaf is the discriminating part).
struct TagPill: View {
    @Environment(\.palette) private var palette
    /// Full `::`-joined tag path.
    let tag: String
    /// When non-nil, shows a remove affordance that reports the full path.
    var onRemove: ((String) -> Void)?

    private var components: [String] {
        tag.split(separator: "::").map(String.init)
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "tag")
                .amgiFont(.micro)
                .foregroundStyle(palette.textTertiary)
            if components.count > 1 {
                Text(components.dropLast().joined(separator: " › ") + " ›")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text((components.last ?? tag).replacingOccurrences(of: "-", with: " "))
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            if onRemove != nil {
                Button {
                    onRemove?(tag)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.surfaceElevated)
        .clipShape(Capsule())
        .help(tag)
        .accessibilityLabel("Tag \(tag)")
    }
}

/// Wrapping row of tag pills. Read-only when `onRemove` is nil.
struct TagPillsView: View {
    let tags: [String]
    var onRemove: ((String) -> Void)?

    var body: some View {
        FlowTagLayout(tags: tags, onRemove: onRemove)
    }
}

/// Left-aligned wrapping layout (no LazyVGrid single-line clipping).
private struct FlowTagLayout: View {
    let tags: [String]
    var onRemove: ((String) -> Void)?

    var body: some View {
        // `Layout` needs iOS 16+/macOS 13+; the package floor is iOS 18 /
        // macOS 15, so no availability gates are needed.
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagPill(tag: tag, onRemove: onRemove)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = layout(proposal: proposal, subviews: subviews)
        for (index, point) in placed.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var points: [CGPoint] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                cursor = CGPoint(x: 0, y: totalHeight)
                rowHeight = 0
            }
            points.append(cursor)
            cursor.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return (CGSize(width: maxWidth.isFinite ? maxWidth : cursor.x, height: totalHeight), points)
    }
}

#if DEBUG
#Preview("Tag pills") {
    VStack(alignment: .leading, spacing: 12) {
        TagPillsView(tags: ["pathophys::topiclist3", "marked", "2025-2026"])
        TagPillsView(tags: ["a::b::c::leaf"]) { _ in }
    }
    .padding()
}
#endif
