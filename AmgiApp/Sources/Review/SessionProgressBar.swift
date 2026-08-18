import SwiftUI
import AmgiTheme
import AnkiKit

/// Compact, glanceable session-progress widget for the reviewer.
///
/// Two things people need at a glance while reviewing: "how far through
/// am I" and "what does this deck look like" (new vs. learning vs. review
/// mix). A single full-bleed bar can only really answer the first
/// question — and only poorly on wide screens, where a razor-thin strip
/// stretched across an iPad or Mac window is hard to read as a proportion.
///
/// This view instead:
/// - caps its own width on regular-width layouts (iPad, Mac) so the bar
///   reads as a proportion rather than a smear across the screen, while
///   staying (nearly) full-width on iPhone;
/// - paints the *entire* track with the session's new/learning/review
///   composition at low opacity, then overlays the same composition at
///   full opacity up to the current position — so colour conveys both the
///   deck's makeup and how much of it is behind you;
/// - surfaces position, percentage, and cards-left as one aligned header
///   directly above the bar, instead of a lone count parked in the
///   navigation bar with no relationship to the bar itself.
struct SessionProgressBar: View {
    /// Category mix frozen at session start — see `ReviewSession.sessionInitialCounts`.
    let initialCounts: DeckCounts
    /// 1-indexed position of the current card.
    let position: Int
    /// Frozen session denominator — see `ReviewSession.sessionProgressTotal`.
    let total: Int
    /// Live "still to review" count for the trailing label.
    let remaining: Int

    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var progressFraction: Double {
        total > 0 ? Double(position) / Double(total) : 0
    }

    private var percent: Int {
        Int((progressFraction * 100).rounded().clamped(to: 0...100))
    }

    /// `nil` lets the bar take the full width offered by its parent
    /// (iPhone); a fixed value keeps it from turning into an
    /// unreadable smear on wider layouts.
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
        // Tight insets keep the track close to the card's edge so it reads
        // as one continuous strip rather than a padded band parked above
        // the card chrome. The capsule's rounded ends stay visible.
        .padding(.horizontal, AmgiSpacing.sm)
        .padding(.vertical, AmgiSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AmgiSpacing.sm) {
            Text("\(position) of \(total) · \(percent)%")
                .amgiFont(.micro)
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: AmgiSpacing.sm)
            Text("\(max(remaining, 0)) left")
                .amgiFont(.captionBold)
                .monospacedDigit()
                .foregroundStyle(palette.accent)
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filledWidth = max(0, width * progressFraction)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.separator)
                composition(width: width, opacity: 0.28)
                composition(width: width, opacity: 1)
                    .frame(width: filledWidth, alignment: .leading)
                    .clipShape(Capsule())
                if progressFraction > 0.015 && progressFraction < 0.995 {
                    Circle()
                        .fill(palette.surface)
                        .overlay(Circle().strokeBorder(palette.accent, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .offset(x: filledWidth - 6)
                }
            }
        }
        .frame(height: 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: progressFraction)
    }

    /// The full new/learning/review composition, rendered at `opacity`.
    /// Called twice: once dimmed as the always-visible "shape of the
    /// deck" backdrop, once at full strength clipped to the progress
    /// fraction as the "done so far" overlay.
    private func composition(width: CGFloat, opacity: Double) -> some View {
        let denominator = max(initialCounts.total, 1)
        return HStack(spacing: 1.5) {
            segment(color: palette.cardStateNew, count: initialCounts.newCount, denominator: denominator, width: width)
            segment(color: palette.cardStateLearning, count: initialCounts.learnCount, denominator: denominator, width: width)
            segment(color: palette.cardStateReview, count: initialCounts.reviewCount, denominator: denominator, width: width)
        }
        .opacity(opacity)
        .clipShape(Capsule())
    }

    private func segment(color: Color, count: Int, denominator: Int, width: CGFloat) -> some View {
        color.frame(width: width * Double(max(count, 0)) / Double(denominator))
    }

    private var accessibilityLabel: String {
        var parts = [
            "Card \(position) of \(total)",
            "\(percent) percent complete",
            "\(max(remaining, 0)) cards left",
        ]
        if initialCounts.newCount > 0 { parts.append("\(initialCounts.newCount) new") }
        if initialCounts.learnCount > 0 { parts.append("\(initialCounts.learnCount) learning") }
        if initialCounts.reviewCount > 0 { parts.append("\(initialCounts.reviewCount) review") }
        return parts.joined(separator: ", ")
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("iPhone-width") {
    VStack(spacing: 24) {
        SessionProgressBar(initialCounts: DeckCounts(newCount: 5, learnCount: 2, reviewCount: 13), position: 1, total: 20, remaining: 19)
        SessionProgressBar(initialCounts: DeckCounts(newCount: 5, learnCount: 2, reviewCount: 13), position: 9, total: 20, remaining: 11)
        SessionProgressBar(initialCounts: DeckCounts(newCount: 5, learnCount: 2, reviewCount: 13), position: 20, total: 20, remaining: 0)
    }
    .padding(.vertical)
}

#Preview("iPad/Mac-width") {
    VStack(spacing: 24) {
        SessionProgressBar(initialCounts: DeckCounts(newCount: 42, learnCount: 8, reviewCount: 130), position: 60, total: 180, remaining: 120)
    }
    .frame(width: 900)
    .padding(.vertical)
}
#endif
