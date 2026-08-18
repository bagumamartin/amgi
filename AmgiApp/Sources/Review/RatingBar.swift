import SwiftUI
import AmgiTheme
import AnkiKit

/// R11 rating row: four elevated cards — surface background, hairline ring,
/// 3px colored top border, next-interval caption above the label.
struct RatingBar: View {
    let intervals: [Rating: String]
    let showIntervals: Bool
    let isDisabled: Bool
    let onRate: (Rating) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.md) {
            ratingCard(.again, label: "Again", color: palette.danger, key: "1")
            ratingCard(.hard, label: "Hard", color: palette.warning, key: "2")
            ratingCard(.good, label: "Good", color: palette.positive, key: "3")
            ratingCard(.easy, label: "Easy", color: palette.info, key: "4")
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

    private func ratingCard(_ rating: Rating, label: String, color: Color, key: String) -> some View {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        // Hardware-keyboard rating (Mac + iPad): 1–4 map to Again–Easy.
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
        .accessibilityLabel("\(label)\(showIntervals ? ", next in \(intervals[rating] ?? "")" : "")")
        #if os(macOS)
        .help("\(label) (\(key))")
        #endif
    }
}

/// Centered post-answer toast — "Good · next in 10m" (R11 answer flow).
struct RatingToastView: View {
    let toast: RatingToast

    @Environment(\.palette) private var palette

    var body: some View {
        Text("\(label) · next in \(toast.interval)")
            .amgiFont(.bodyEmphasis)
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(palette.surfaceElevated, in: Capsule())
            .overlay {
                Capsule().strokeBorder(palette.separator, lineWidth: 1)
            }
    }

    private var label: String {
        switch toast.rating {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
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

#Preview("Toast") {
    RatingToastView(toast: RatingToast(rating: .good, interval: "10m"))
}
#endif
