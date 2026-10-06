// AmgiFeatures/Sources/WidgetFeature/SmallWidgetView.swift
import Foundation
import SwiftUI
import WidgetKit
import AmgiTheme
import AmgiAppCore

struct SmallWidgetView: View {
    @Environment(\.palette) private var palette
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(snapshot.deckName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text("🔥")
                        .font(.system(size: 14))
                    Text("\(snapshot.streak)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.warning)
                    Text("d")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 6)

            WidgetConcentricRings(snapshot: snapshot, size: 92)

            Spacer(minLength: 4)

            // Summary legend: coloured dots and numbers only, no words —
            // with the done-today number at the right end past a divider.
            HStack(spacing: 6) {
                legendDot(color: palette.cardStateNew, count: snapshot.newCount)
                legendDot(color: palette.cardStateLearning, count: snapshot.learnCount)
                legendDot(color: palette.cardStateReview, count: snapshot.reviewCount)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                Text("\(snapshot.completedToday)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 15)
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

private extension SmallWidgetView {
    func legendDot(color: Color, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

#if DEBUG

// Deliberately a plain SwiftUI preview with a hand-set frame — no WidgetKit
// preview API. Anything that marks this as a *widget* preview (`#Preview(as:)`
// or `WidgetPreviewContext`, in either the macro or the PreviewProvider form)
// makes Xcode look for a widget-extension process to host it. A file in the
// package target is previewed by XCPreviewAgent, which is an app, so the
// preview fails with "No candidates found to host preview" — the build graph
// tags the node `(SmallWidgetView.swift, Previews, widget)` and finds no
// candidate. Nothing in the package can supply that host; only moving these
// files back into the AmgiWidget target would.
#Preview {
    SmallWidgetView(snapshot: .placeholder)
        .frame(width: 170, height: 170)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
}
#endif
