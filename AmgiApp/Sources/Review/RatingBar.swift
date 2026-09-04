import SwiftUI
import AmgiTheme
import AnkiKit
import Sharing

/// R11 rating row: four elevated cards — surface background, hairline ring,
/// 3px colored top border, next-interval caption above the label.
struct RatingBar: View {
    let intervals: [Rating: String]
    let showIntervals: Bool
    let isDisabled: Bool
    let onRate: (Rating) -> Void

    @Environment(\.palette) private var palette
    @Shared(.reviewShortcuts) private var reviewShortcuts: [String: ReviewShortcut] = [:]

    var body: some View {
        // Ratings reuse the category-state hues (Again/Hard/Good/Easy ↔
        // relearn/learning/review/new) so the buttons, count dots, badges,
        // rings, and progress fills all speak one palette in every theme.
        HStack(spacing: AmgiSpacing.md) {
            ratingCard(.again, label: "Again", color: palette.cardStateRelearn)
            ratingCard(.hard, label: "Hard", color: palette.cardStateLearning)
            ratingCard(.good, label: "Good", color: palette.cardStateReview)
            ratingCard(.easy, label: "Easy", color: palette.cardStateNew)
        }
        // Four equal actions should remain a single, easy-to-compare group.
        // On wide iPad windows, letting each card claim a quarter of the
        // screen makes the controls look disconnected and increases reach.
        // The cap is larger than every compact width, so iPhone keeps its
        // full-width HIG-friendly layout while iPad centers a comfortable row.
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.vertical, AmgiSpacing.md)
        #if !os(macOS)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        #endif
    }

    @ViewBuilder
    private func ratingCard(_ rating: Rating, label: String, color: Color) -> some View {
        let action = ReviewShortcutAction.ratingAction(for: rating)
        let binding = reviewShortcuts[action.rawValue] ?? action.defaultShortcut
        let keyDisplay = binding.displayString
        Button {
            onRate(rating)
        } label: {
            #if os(macOS)
            // macOS HIG: standard bordered controls (tinted per rating)
            // instead of the iOS elevated-card layout — compact, with the
            // next-interval caption as secondary text.
            VStack(spacing: 2) {
                Text(label)
                    .fontWeight(.medium)
                if showIntervals {
                    Text(intervals[rating] ?? " ")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .frame(minWidth: 84)
            .padding(.vertical, 2)
            #else
            VStack(spacing: 4) {
                if showIntervals {
                    Text(intervals[rating] ?? " ")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Text(label)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(palette.surface)
            .overlay(alignment: .top) {
                color
                    .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                    .strokeBorder(palette.separator, lineWidth: 1)
            }
            .amgiChromeShadow(
                RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous),
                radius: 4,
                x: 0,
                y: 2,
                opacity: 0.08
            )
            #endif
        }
        #if os(macOS)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(color)
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isDisabled)
        // Fallback when the review surface isn't key-focused. Arrow-key
        // bindings use mapped `.upArrow` equivalents (see ReviewShortcut).
        // iPad still needs `.onKeyPress` — the focus engine swallows arrows
        // before these shortcuts. Duplicate fires are no-ops (`isAdvancing`).
        .keyboardShortcut(binding.keyEquivalent, modifiers: binding.modifiers)
        .accessibilityLabel("\(label)\(showIntervals ? ", next in \(intervals[rating] ?? "")" : "")")
        #if os(macOS)
        .help("\(label) (\(keyDisplay))")
        #endif
    }
}

#if DEBUG
#Preview("Rating bar") {
    RatingBar(
        intervals: [.again: "<1m", .hard: "8m", .good: "10m", .easy: "4d"],
        showIntervals: true,
        isDisabled: false,
        onRate: { _ in }
    )
}
#endif
