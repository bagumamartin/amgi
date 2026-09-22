public import SwiftUI
import AmgiTheme

/// Shown when a review has nothing left today. Quiet stats, then Done.
public struct SessionDoneContent: View {
    let title: String
    let subtitle: String
    let reviewed: Int
    let accuracyPercent: Int?
    let timeLabel: String
    let graduatedToday: Int
    let onDone: () -> Void

    @Environment(\.palette) private var palette

    public init(
        title: String,
        subtitle: String,
        reviewed: Int,
        accuracyPercent: Int?,
        timeLabel: String,
        graduatedToday: Int,
        onDone: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.reviewed = reviewed
        self.accuracyPercent = accuracyPercent
        self.timeLabel = timeLabel
        self.graduatedToday = graduatedToday
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                    Text(title)
                        .amgiFont(.displayHero)
                        .foregroundStyle(palette.textPrimary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .amgiFont(.body)
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                AmgiCard {
                    VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                        stat("Reviewed", value: "\(reviewed)")
                        stat("Accuracy", value: accuracyPercent.map { "\($0)%" } ?? "—")
                        stat("Time", value: timeLabel)
                        if graduatedToday > 0 {
                            Text(graduatedToday == 1
                                 ? "1 card graduated today"
                                 : "\(graduatedToday) cards graduated today")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                                .padding(.top, AmgiSpacing.xs)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Done", action: onDone)
                    .buttonStyle(AmgiPrimaryButtonStyle())
            }
            .padding(.horizontal, AmgiSpacing.lg)
            .padding(.vertical, AmgiSpacing.xl)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .amgiScreenCanvas()
    }

    private func stat(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
        }
    }
}
