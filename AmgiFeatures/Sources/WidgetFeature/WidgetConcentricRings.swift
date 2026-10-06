import SwiftUI
import AmgiAppCore
import AmgiTheme

/// The widget-side twin of Study's three-ring visualization. Widgets cannot
/// import AmgiUI (the extension stays on the engine-free sink), so the small
/// amount of geometry is intentionally duplicated here and kept deliberately
/// boring: one dim track per ring plus a bold completed-share arc per ring,
/// mirroring the Today card's rings, and a compact center.
struct WidgetConcentricRings: View {
    let snapshot: WidgetSnapshot
    var size: CGFloat = 110
    var showsCaption: Bool = true

    @Environment(\.palette) private var palette

    private var strokeWidth: CGFloat { max(3, size * 0.042) }
    private var ringGap: CGFloat { max(1.5, size * 0.018) }
    private var outerDiameter: CGFloat { size - strokeWidth }

    /// Completed share of the day — the single source of truth for every
    /// ring's fill, matching the Today card. Per-category completion is
    /// not tracked, so no ring invents its own.
    private var progress: Double {
        snapshot.todayProgressFraction
    }

    private var categories: [(name: String, count: Int, color: Color)] {
        [
            ("new", snapshot.newCount, palette.cardStateNew),
            ("learning", snapshot.learnCount, palette.cardStateLearning),
            ("review", snapshot.reviewCount, palette.cardStateReview)
        ]
    }

    var body: some View {
        ZStack {
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                Circle()
                    .stroke(category.color.opacity(0.18), lineWidth: strokeWidth)
                    .frame(width: diameter(for: index), height: diameter(for: index))
            }
            if progress > 0 {
                ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(category.color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: progress < 1 ? .round : .butt))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter(for: index), height: diameter(for: index))
                }
            }
            center
        }
        .frame(width: size, height: size)
        .shadow(
            color: palette.positive.opacity(progress * 0.45),
            radius: progress >= 1 ? 10 : 0
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func diameter(for index: Int) -> CGFloat {
        max(24, outerDiameter - CGFloat(index) * (strokeWidth + ringGap) * 2)
    }

    /// Clear width inside the innermost stroke, mirroring the Today
    /// card's ring. Centre text is pinned to this so it never collides
    /// with the rings.
    private var innerClearWidth: CGFloat {
        max(30, diameter(for: 2) - strokeWidth)
    }

    private var center: some View {
        VStack(spacing: size >= 100 ? 2 : 1) {
            if showsCaption {
                Text(snapshot.totalDue > 0 ? "DUE" : "CLEAR")
                    .font(.system(size: max(7, size * 0.07), weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(palette.textSecondary)
            }
            Text("\(snapshot.totalDue)")
                .font(.system(size: size >= 100 ? 28 : 22, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("\(Int((snapshot.todayProgressFraction * 100).rounded()))%")
                .font(.system(size: max(7, size * 0.07), weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
            Text(L10n.text("Done"))
                .font(.system(size: max(7, size * 0.07), weight: .medium, design: .rounded))
                .foregroundStyle(palette.textTertiary)
        }
        .frame(maxWidth: innerClearWidth)
        // Same optical nudge as the Today card, proportional to size.
        .offset(y: size * 0.02)
    }

    private var accessibilityLabel: String {
        guard snapshot.totalDue > 0 else {
            return "Nothing due today"
        }
        return "\(snapshot.totalDue) cards due. \(snapshot.newCount) new, \(snapshot.learnCount) learning, \(snapshot.reviewCount) review. \(Int((snapshot.todayProgressFraction * 100).rounded())) percent complete."
    }
}

#if DEBUG
#Preview {
    WidgetConcentricRings(snapshot: .placeholder, size: 110)
        .frame(width: 170, height: 170)
        .background(.fill.tertiary, in: .rect(cornerRadius: AmgiRadius.sheet))
        .environment(\.palette, .vividLight)
}
#endif
