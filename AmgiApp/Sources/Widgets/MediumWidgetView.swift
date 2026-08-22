// AmgiApp/Sources/Widgets/MediumWidgetView.swift
import SwiftUI
import WidgetKit
import AmgiTheme

struct MediumWidgetView: View {
    @Environment(\.palette) private var palette
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 16) {
            // Left: streak + due ring (mirrors the small widget)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("🔥")
                        .font(.system(size: 16))
                    Text("\(snapshot.streak)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.warning)
                    Text("day streak")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 6)

                SmallDueRing(snapshot: snapshot)

                Spacer(minLength: 4)
            }
            .frame(maxHeight: .infinity)

            // Divider
            Rectangle()
                .fill(.separator)
                .frame(width: 1)

            // Right: category breakdown + done today
            VStack(alignment: .leading, spacing: 9) {
                // Category dots ride the theme's card-state hues so the
                // widget matches the in-app badges, rings, and rating row.
                countRow(dot: palette.cardStateNew, label: "New", count: snapshot.newCount)
                countRow(dot: palette.cardStateLearning, label: "Learn", count: snapshot.learnCount)
                countRow(dot: palette.cardStateReview, label: "Review", count: snapshot.reviewCount)

                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)

                HStack {
                    Text("Done today")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                    Spacer()
                    Text("\(snapshot.reviewedToday)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .frame(minWidth: 108)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "amgi://study"))
    }

}

private extension MediumWidgetView {
    func countRow(dot: Color, label: String, count: Int) -> some View {
        HStack {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }
}

#Preview(as: .systemMedium) {
    AmgiWidget()
} timeline: {
    WidgetEntry(date: Date(), snapshot: .placeholder)
}