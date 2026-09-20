import Testing
import SwiftUI
@testable import AmgiUI
@testable import AmgiTheme

@MainActor
@Suite("AmgiHeroSummary")
struct AmgiHeroSummaryTests {
    @Test func buildsWithAllSlots() {
        _ = AmgiHeroSummary(
            eyebrow: "Due today",
            bigNumber: "127",
            subtitle: "cards across 4 decks",
            decoration: { Image(systemName: "chart.line.uptrend.xyaxis") },
            footer: { Button("Start") {} },
            sidecar: { Color.clear.frame(height: 28) }
        )
        .environment(\.palette, .vividLight)
    }

    @Test func buildsWithNoEyebrowOrSubtitle() {
        _ = AmgiHeroSummary(
            eyebrow: nil,
            bigNumber: "0",
            subtitle: nil,
            decoration: { EmptyView() },
            footer: { EmptyView() }
        )
        .environment(\.palette, .vividDark)
    }
}
