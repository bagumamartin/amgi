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
            background: .gradient(start: .blue, end: .purple),
            decoration: { Image(systemName: "chart.line.uptrend.xyaxis") },
            footer: { Button("Start") {} }
        )
    }

    @Test func buildsWithNoEyebrowOrSubtitle() {
        _ = AmgiHeroSummary(
            eyebrow: nil,
            bigNumber: "0",
            subtitle: nil,
            background: .solid(.blue),
            decoration: { EmptyView() },
            footer: { EmptyView() }
        )
    }
}
