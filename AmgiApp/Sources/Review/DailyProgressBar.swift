import SwiftUI
import AmgiTheme
import AnkiKit

/// Compact daily-progress strip for the reviewer.
///
/// The fill tracks completed cards (those that have graduated past today's
/// scope) as a fraction of the *live* total — `completed / (completed +
/// remaining)`. Using live remaining keeps the bar honest: it can't read 100%
/// while cards are still due, and it self-corrects if more cards appear
/// mid-session. A dim segmented backdrop shows the remaining new/learning/
/// review mix; the fill is that same composition at full strength, revealed
/// up to the progress point — single-category decks stay one hue throughout,
/// and multi-category hue flips land exactly on the backdrop's boundaries.
struct DailyProgressBar<Center: View>: View {
    /// Cards graduated past today's scope in this scope (re-answers don't count).
    let completedToday: Int
    /// Live cards still due today for the current scope.
    let remainingToday: Int
    /// Live new/learning/review composition for the dim "what's left" backdrop.
    let remainingCounts: DeckCounts
    /// Optional content centered in the header row, at the horizontal
    /// midpoint of the bar (the review context dots).
    var center: Center

    init(
        completedToday: Int,
        remainingToday: Int,
        remainingCounts: DeckCounts,
        @ViewBuilder center: () -> Center = { EmptyView() }
    ) {
        self.completedToday = completedToday
        self.remainingToday = remainingToday
        self.remainingCounts = remainingCounts
        self.center = center()
    }

    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var total: Int { max(completedToday + remainingToday, 1) }

    private var progressFraction: Double {
        min(1, Double(max(completedToday, 0)) / Double(total))
    }

    private var percent: Int {
        Int((progressFraction * 100).rounded())
    }

    /// `nil` lets the bar take the full width offered by its parent
    /// (iPhone); a fixed value keeps it from turning into an unreadable
    /// smear on wider layouts.
    private var maxWidth: CGFloat? {
        #if os(macOS)
        420
        #elseif os(iOS)
        horizontalSizeClass == .regular ? 480 : nil
        #else
        nil
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            header
            track
        }
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AmgiSpacing.sm)
        .padding(.vertical, AmgiSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        // ZStack (not edge-to-edge HStack) so `center` sits at the true
        // horizontal midpoint of the bar regardless of the side texts'
        // widths.
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: AmgiSpacing.sm) {
                Text("\(completedToday) of \(total) · \(percent)%")
                    .amgiFont(.micro)
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: AmgiSpacing.sm)
                Text("\(max(remainingToday, 0)) left")
                    .amgiFont(.captionBold)
                    .monospacedDigit()
                    .foregroundStyle(palette.accent)
            }
            center
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                remainingComposition(width: width)
                completedComposition(width: width)
            }
        }
        .frame(height: 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: progressFraction)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: remainingCounts)
    }

    /// Dim segmented backdrop — the live remaining new/learning/review mix.
    @ViewBuilder
    private func remainingComposition(width: CGFloat) -> some View {
        if remainingCounts.total <= 0 {
            Capsule().fill(palette.separator).opacity(0.35)
        } else {
            compositionStack(width: width)
                .opacity(0.35)
                .clipShape(Capsule())
        }
    }

    /// The fill: a full-strength copy of the same composition, revealed up
    /// to the progress point so each category lights up in place and hue
    /// flips land exactly on the dim backdrop's boundaries. With no mix left
    /// (day complete) it falls back to the solid positive capsule.
    @ViewBuilder
    private func completedComposition(width: CGFloat) -> some View {
        let filledWidth = max(0, min(width, width * progressFraction))
        if remainingCounts.total <= 0 {
            Capsule()
                .fill(palette.positive)
                .frame(width: filledWidth, height: 10)
        } else {
            compositionStack(width: width)
                .clipShape(Capsule())
                .mask(alignment: .leading) {
                    Capsule().frame(width: filledWidth)
                }
        }
    }

    /// New/learning/review segments separated by hairline gaps. Widths are
    /// computed over the usable width (total minus gaps) and the LAST
    /// visible segment absorbs any rounding remainder — so the fill always
    /// reaches the capsule's rounded end even when a tail category (e.g.
    /// review) is exhausted. Without that, a zero-width tail segment leaves
    /// the bar ending on a flat segment boundary that reads as clipped.
    /// Zero-count segments are omitted entirely rather than reserving their
    /// gap. The explicit `width` frame also gives `clipShape(Capsule())` an
    /// exact pill to clip against (the HStack alone would be wider by the
    /// gaps, shifting the rounding past the visible end).
    private func compositionStack(width: CGFloat) -> some View {
        let spacing: CGFloat = 1.5
        let segments: [(color: Color, count: Int)] = [
            (palette.cardStateNew, remainingCounts.newCount),
            (palette.cardStateLearning, remainingCounts.learnCount),
            (palette.cardStateReview, remainingCounts.reviewCount),
        ]
        let total = max(remainingCounts.total, 1)
        let visible = segments.filter { $0.count > 0 }
        let gaps = CGFloat(max(visible.count - 1, 0)) * spacing
        let usable = max(width - gaps, 0)

        var widths = visible.map { usable * Double($0.count) / Double(total) }
        if let last = widths.indices.last {
            widths[last] = max(usable - widths.dropLast().reduce(0, +), 0)
        }

        return HStack(spacing: spacing) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, segment in
                segment.color.frame(width: widths[index])
            }
        }
        .frame(width: width, height: 10, alignment: .leading)
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(completedToday) of \(total) today",
            "\(percent) percent complete",
            "\(max(remainingToday, 0)) cards left",
        ]
        if remainingCounts.newCount > 0 { parts.append("\(remainingCounts.newCount) new") }
        if remainingCounts.learnCount > 0 { parts.append("\(remainingCounts.learnCount) learning") }
        if remainingCounts.reviewCount > 0 { parts.append("\(remainingCounts.reviewCount) review") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Mid-day") {
    VStack(spacing: 24) {
        DailyProgressBar(
            completedToday: 10,
            remainingToday: 30,
            remainingCounts: DeckCounts(newCount: 8, learnCount: 6, reviewCount: 16)
        )
        DailyProgressBar(
            completedToday: 32,
            remainingToday: 8,
            remainingCounts: DeckCounts(newCount: 0, learnCount: 3, reviewCount: 5)
        )
        DailyProgressBar(
            completedToday: 40,
            remainingToday: 0,
            remainingCounts: DeckCounts(newCount: 0, learnCount: 0, reviewCount: 0)
        )
    }
    .padding(.vertical)
}

#Preview("iPad/Mac-width") {
    VStack(spacing: 24) {
        DailyProgressBar(
            completedToday: 70,
            remainingToday: 110,
            remainingCounts: DeckCounts(newCount: 42, learnCount: 8, reviewCount: 60)
        )
    }
    .frame(width: 900)
    .padding(.vertical)
}
#endif
