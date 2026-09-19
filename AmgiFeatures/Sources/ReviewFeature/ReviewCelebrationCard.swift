import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiReviewCore
import AnkiKit

/// A beautifully polished, multi-platform congratulatory card displayed when a review
/// session completes with no cards left unfinished.
/// Adapts gracefully across iPhone, iPad, Mac, and Apple Watch.
struct ReviewCelebrationCard: View {
    let deckName: String
    let sessionStats: SessionStats
    let dailyCompletedToday: Int
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hasAppeared = false

    init(
        deckName: String,
        sessionStats: SessionStats,
        dailyCompletedToday: Int,
        onDismiss: @escaping () -> Void
    ) {
        self.deckName = deckName
        self.sessionStats = sessionStats
        self.dailyCompletedToday = dailyCompletedToday
        self.onDismiss = onDismiss
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AmgiSpacing.xl) {
                Spacer(minLength: AmgiSpacing.xs)

                heroEmblem

                headerSection

                statsGrid
                    .offset(y: hasAppeared ? 0 : 16)
                    .opacity(hasAppeared ? 1.0 : 0.0)
                    .animation(AmgiMotion.standard, value: hasAppeared)

                if dailyCompletedToday > 0 {
                    dailyGraduationBanner
                        .offset(y: hasAppeared ? 0 : 16)
                        .opacity(hasAppeared ? 1.0 : 0.0)
                        .animation(AmgiMotion.standard, value: hasAppeared)
                }

                Spacer(minLength: AmgiSpacing.sm)

                actionButton
                    .padding(.bottom, AmgiSpacing.sm)
            }
            .padding(.horizontal, AmgiSpacing.lg)
            .padding(.vertical, AmgiSpacing.md)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background)
        .onAppear {
            #if os(iOS)
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(.success)
            #endif
            withAnimation(AmgiMotion.momentum) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Hero Emblem

    private var heroEmblem: some View {
        ZStack {
            // Soft ambient glowing halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.positive.opacity(0.28),
                            palette.positive.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 65
                    )
                )
                .frame(width: 130, height: 130)

            // Outer subtle stroke ring
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            palette.positive.opacity(0.5),
                            palette.positive.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 92, height: 92)

            // Ambient depth disc
            Circle()
                .fill(palette.positive.opacity(0.16))
                .frame(width: 86, height: 86)

            // Inner solid luminous circle
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            palette.positive,
                            palette.positive.opacity(0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 78, height: 78)

            // Clean, bold checkmark
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            // Celebratory sparkle accent
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.warning)
                .offset(x: 36, y: -30)
                .scaleEffect(hasAppeared ? 1.0 : 0.4)
                .opacity(hasAppeared ? 1.0 : 0.0)
                .animation(AmgiMotion.momentum, value: hasAppeared)
        }
        .scaleEffect(hasAppeared ? 1.0 : 0.65)
        .opacity(hasAppeared ? 1.0 : 0.0)
        .accessibilityHidden(true)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: AmgiSpacing.xs) {
            // Milestone pill
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("SESSION COMPLETE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
            }
            .foregroundStyle(palette.positive)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(palette.positive.opacity(0.12))
            )
            .padding(.bottom, 2)

            Text("All Done for Today!")
                .amgiFont(.displayHero)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(deckScopeDescription)
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AmgiSpacing.xs)
        }
    }

    private var deckScopeDescription: String {
        let name = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "All Decks" {
            return "You're all caught up across all decks for today."
        } else {
            let cleanName = name.components(separatedBy: "::").last ?? name
            return "You're all caught up on \(cleanName) for today."
        }
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: AmgiSpacing.md),
                GridItem(.flexible(), spacing: AmgiSpacing.md)
            ],
            spacing: AmgiSpacing.md
        ) {
            bentoCard(
                icon: "rectangle.stack.fill",
                title: "\(sessionStats.reviewed)",
                subtitle: "Reviewed",
                tint: palette.accent
            )

            bentoCard(
                icon: "target",
                title: sessionStats.reviewed > 0 ? "\(Int(sessionStats.accuracy * 100))%" : "—",
                subtitle: "Accuracy",
                tint: palette.positive
            )

            bentoCard(
                icon: "clock.fill",
                title: formattedTime(sessionStats.totalTimeMs),
                subtitle: "Time Spent",
                tint: palette.accent
            )

            bentoCard(
                icon: "bolt.fill",
                title: formattedPace(reviewed: sessionStats.reviewed, totalTimeMs: sessionStats.totalTimeMs),
                subtitle: "Avg Pace",
                tint: palette.warning
            )
        }
    }

    private func bentoCard(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .amgiFont(.sectionHeading, .monospacedDigits)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(subtitle)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(AmgiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                .fill(palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                .stroke(palette.border.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Graduation Milestone Banner

    private var dailyGraduationBanner: some View {
        HStack(spacing: AmgiSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .fill(palette.warning.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: "flame.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(palette.warning)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(dailyCompletedToday) Card\(dailyCompletedToday == 1 ? "" : "s") Graduated Today")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)

                Text("Moved past learning into your long-term review schedule.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer()
        }
        .padding(AmgiSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.warning.opacity(0.08),
                            palette.danger.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                .stroke(palette.warning.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button(action: onDismiss) {
            Text("Done")
                .amgiFont(.bodyEmphasis)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
        }
        .buttonStyle(AmgiPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        #if os(macOS)
        .keyboardShortcut(.cancelAction)
        #endif
    }

    // MARK: - Formatting Helpers

    private func formattedTime(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes > 0 ? "\(hours)h \(remMinutes)m" : "\(hours)h"
    }

    private func formattedPace(reviewed: Int, totalTimeMs: Int) -> String {
        guard reviewed > 0 else { return "—" }
        let secondsPerCard = Double(totalTimeMs) / 1000.0 / Double(reviewed)
        return String(format: "%.1fs / card", secondsPerCard)
    }
}
