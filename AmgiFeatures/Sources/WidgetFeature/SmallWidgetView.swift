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
        VStack(alignment: .leading, spacing: 0) {
            // Streak row
            HStack(spacing: 4) {
                Text("🔥")
                    .font(.system(size: 17))
                Text("\(snapshot.streak)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.warning)
                Text("day streak")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }

            Spacer()

            // Hero due count
            VStack(alignment: .leading, spacing: 2) {
                Text("\(snapshot.totalDue)")
                    .font(.system(size: 54, weight: .bold, design: .default))
                    .foregroundStyle(palette.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .kerning(-2)
                Text("cards due")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()

            // Deck name
            Text(snapshot.deckName)
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "amgi://review?deckId=\(snapshot.deckId)"))
    }
}

#if DEBUG

// Deliberately a plain SwiftUI preview with a hand-set frame — no WidgetKit
// preview API. Anything that marks this as a *widget* preview (`#Preview(as:)`
// or `WidgetPreviewContext`, in either the macro or the PreviewProvider form)
// makes Xcode look for a widget-extension process to host it. A file in a
// package target is previewed by XCPreviewAgent, which is an app, so the
// preview fails with "No candidates found to host preview" — the build graph
// tags the node `(SmallWidgetView.swift, Previews, widget)` and finds no
// candidate. Nothing in the package can supply that host; only moving these
// files back into the AmgiWidget target would.
//
// So: the real view, at the nominal small-widget size, with the widget's
// rounded background faked. Palette falls back to the `\.palette` default
// rather than ThemeManager's live theme.
#Preview {
    SmallWidgetView(snapshot: .placeholder)
        .frame(width: 170, height: 170)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
}
#endif
