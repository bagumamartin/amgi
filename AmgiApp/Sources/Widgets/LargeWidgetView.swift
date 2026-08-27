// AmgiApp/Sources/Widgets/LargeWidgetView.swift
import SwiftUI
import WidgetKit
import AmgiTheme

struct LargeWidgetView: View {
    @Environment(\.palette) private var palette
    let snapshot: WidgetSnapshot

    private var totalDue: Int { snapshot.totalDue }

    private var progressFraction: Double { snapshot.todayProgressFraction }

    private var chartMax: Int {
        snapshot.lastSevenDays.max() ?? 1
    }

    private let chartHeight: CGFloat = 64
    private let barAreaHeight: CGFloat = 49

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header: deck name + streak pill
            HStack {
                Text(snapshot.deckName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                streakPill
            }
            .padding(.bottom, 6)

            // Hero due count
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(totalDue)")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .kerning(-2.5)
                Text("cards due")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(.bottom, 4)

            // Multisegment progress bar (collection-wide, mirrors the reviewer)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .leading) {
                        remainingComposition(width: width)
                        completedComposition(width: width)
                    }
                }
                .frame(height: 10)

                Text("\(snapshot.completedToday) done · \(totalDue) remaining today")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 12)

            // 3-column breakdown
            HStack(spacing: 0) {
                // Category dots ride the theme's card-state hues so the
                // widget matches the in-app badges, rings, and rating row.
                breakdownColumn(color: palette.cardStateNew, label: "New", count: snapshot.newCount)
                Divider()
                breakdownColumn(color: palette.cardStateLearning, label: "Learn", count: snapshot.learnCount)
                Divider()
                breakdownColumn(color: palette.cardStateReview, label: "Review", count: snapshot.reviewCount)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 10)

            // 7-day bar chart
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 7 Days")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                    .textCase(.uppercase)
                    .kerning(0.3)

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(snapshot.lastSevenDays.enumerated()), id: \.offset) { index, count in
                        VStack(spacing: 3) {
                            let fraction = chartMax > 0 ? CGFloat(count) / CGFloat(chartMax) : 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(palette.accent.opacity(index == 6 ? 0.9 : 0.5))
                                .frame(height: max(3, barAreaHeight * fraction))
                            Text(dayLabel(index))
                                .font(.system(size: 9))
                                .foregroundStyle(index == 6 ? palette.textPrimary.opacity(0.6) : palette.textPrimary.opacity(0.25))
                        }
                    }
                }
                .frame(height: chartHeight)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "amgi://study"))
    }

    private var streakPill: some View {
        HStack(spacing: 4) {
            Text("🔥")
                .font(.system(size: 13))
            Text("\(snapshot.streak) day streak")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.warning)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(palette.warning.opacity(0.12), in: Capsule())
    }

    private let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]
}

private extension LargeWidgetView {
    /// Dim segmented backdrop — the live remaining new/learning/review mix.
    /// Stays subtle so the full-strength completion fill reads as progress.
    @ViewBuilder
    func remainingComposition(width: CGFloat) -> some View {
        let total = snapshot.newCount + snapshot.learnCount + snapshot.reviewCount
        if total <= 0 {
            Capsule().fill(palette.separator).opacity(0.35)
        } else {
            compositionStack(width: width)
                .opacity(0.35)
                .clipShape(Capsule())
        }
    }

    /// The fill: the same composition at full strength, revealed up to the
    /// progress point — each category lights up in place and hue flips land
    /// exactly on the dim backdrop's boundaries. With no mix left (day done)
    /// it falls back to the solid positive capsule.
    @ViewBuilder
    func completedComposition(width: CGFloat) -> some View {
        let filledWidth = max(0, min(width, width * progressFraction))
        if snapshot.newCount + snapshot.learnCount + snapshot.reviewCount <= 0 {
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

    private func compositionStack(width: CGFloat) -> some View {
        let total = snapshot.newCount + snapshot.learnCount + snapshot.reviewCount
        return HStack(spacing: 1.5) {
            segment(color: palette.cardStateNew, count: snapshot.newCount, denominator: total, width: width)
            segment(color: palette.cardStateLearning, count: snapshot.learnCount, denominator: total, width: width)
            segment(color: palette.cardStateReview, count: snapshot.reviewCount, denominator: total, width: width)
        }
    }

    func segment(color: Color, count: Int, denominator: Int, width: CGFloat) -> some View {
        color.frame(width: width * Double(max(count, 0)) / Double(max(denominator, 1)))
    }

    func breakdownColumn(color: Color, label: String, count: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .kerning(-0.8)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    func dayLabel(_ index: Int) -> String {
        let today = Calendar.current.component(.weekday, from: snapshot.snapshotDate)
        // weekday: 1=Sun, 2=Mon, ..., 7=Sat — map to 0=Mon..6=Sun
        let todayIndex = (today + 5) % 7
        let dayIndex = (todayIndex - (6 - index) + 7) % 7
        return weekdayLabels[dayIndex]
    }
}

#Preview(as: .systemLarge) {
    AmgiWidget()
} timeline: {
    WidgetEntry(date: Date(), snapshot: .placeholder)
}
