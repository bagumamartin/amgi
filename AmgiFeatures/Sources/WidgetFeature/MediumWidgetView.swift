// AmgiFeatures/Sources/WidgetFeature/MediumWidgetView.swift
import Foundation
import SwiftUI
import WidgetKit
import AmgiTheme
import AmgiAppCore

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

                WidgetConcentricRings(snapshot: snapshot, size: 110)

                Spacer(minLength: 4)
            }
            .frame(maxHeight: .infinity)

            // Divider
            Rectangle()
                .fill(.separator)
                .frame(width: 1)

            // Right: configured deck context, category breakdown, and done today
            VStack(alignment: .leading, spacing: 9) {
                Text(snapshot.deckName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

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
                    Text("\(snapshot.completedToday)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .frame(minWidth: 108)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(studyURL)
    }

    private var studyURL: URL {
        var components = URLComponents()
        components.scheme = "amgi"
        components.host = "study"
        var items = [URLQueryItem(name: "deckId", value: String(snapshot.deckId))]
        if let profileID = snapshot.profileID {
            items.append(URLQueryItem(name: "profileID", value: profileID))
        }
        components.queryItems = items
        return components.url!
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
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }
}

#if DEBUG

// See the note on SmallWidgetView's preview for why this uses a hand-set frame
// instead of any WidgetKit preview API.
#Preview {
    MediumWidgetView(snapshot: .placeholder)
        .frame(width: 364, height: 170)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
}
#endif
