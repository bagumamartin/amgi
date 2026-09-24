import SwiftUI
import AmgiAppCore
import AmgiTheme

/// The widget-side twin of Study's three-ring visualization. Widgets cannot
/// import AmgiUI (the extension stays on the engine-free sink), so the small
/// amount of geometry is intentionally duplicated here and kept deliberately
/// boring: three category arcs, one dim track per ring, and a compact center.
struct WidgetConcentricRings: View {
    let snapshot: WidgetSnapshot
    var size: CGFloat = 110
    var showsCaption: Bool = true

    @Environment(\.palette) private var palette

    private var strokeWidth: CGFloat { max(3, size * 0.042) }
    private var ringGap: CGFloat { max(1.5, size * 0.018) }
    private var outerDiameter: CGFloat { size - strokeWidth }

    private var categories: [(name: String, count: Int, color: Color)] {
        [
            ("new", snapshot.newCount, palette.cardStateNew),
            ("learning", snapshot.learnCount, palette.cardStateLearning),
            ("review", snapshot.reviewCount, palette.cardStateReview)
        ]
    }

    private var total: Int { max(snapshot.totalDue, 0) }

    var body: some View {
        ZStack {
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                Circle()
                    .stroke(category.color.opacity(0.18), lineWidth: strokeWidth)
                    .frame(width: diameter(for: index), height: diameter(for: index))
            }
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                let share = total > 0 ? Double(max(category.count, 0)) / Double(total) : 0
                if share > 0 {
                    Circle()
                        .trim(from: 0, to: min(max(share, 0.015), 1))
                        .stroke(category.color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter(for: index), height: diameter(for: index))
                }
            }
            center
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func diameter(for index: Int) -> CGFloat {
        max(24, outerDiameter - CGFloat(index) * (strokeWidth + ringGap) * 2)
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
                .minimumScaleFactor(0.55)
                .lineLimit(1)
            Text("\(Int((snapshot.todayProgressFraction * 100).rounded()))%")
                .font(.system(size: max(7, size * 0.07), weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
            progressIndicator
        }
    }

    private var progressIndicator: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.separator.opacity(0.55))
                Capsule()
                    .fill(palette.accent)
                    .frame(width: proxy.size.width * snapshot.todayProgressFraction)
            }
        }
        .frame(width: min(max(size * 0.36, 30), 58), height: 3)
        .accessibilityHidden(true)
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
