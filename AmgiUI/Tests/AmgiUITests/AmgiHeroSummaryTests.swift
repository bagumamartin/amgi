import Testing
import SwiftUI
@testable import AmgiUI
@testable import AmgiTheme

@MainActor
@Suite("AmgiHeroSummary")
struct AmgiHeroSummaryTests {
    @Test func buildsWithAllSlots() {
        _ = AmgiHeroSummary(
            header: { Color.clear.frame(height: 28) },
            footer: { Color.clear.frame(height: 28) },
            sidecar: { Color.clear.frame(height: 28) }
        )
        .environment(\.palette, .vividLight)
    }

    @Test func buildsWithNoEyebrowOrSubtitle() {
        _ = AmgiHeroSummary(
            header: { EmptyView() },
            footer: { EmptyView() },
            sidecar: { EmptyView() }
        )
        .environment(\.palette, .vividDark)
    }
}

@Suite("HeroTodayStats")
struct HeroTodayStatsTests {
    @Test func paceDividesTimeByStudied() {
        let stats = HeroTodayStats(studied: 3, timeMillis: 128_100)
        #expect(abs(stats.paceSecondsPerCard - 42.7) < 0.05)
    }

    @Test func retentionIsTrueRetentionShare() {
        let stats = HeroTodayStats(studied: 128, timeMillis: 2_731_000, retentionPassed: 109, retentionTotal: 128)
        #expect(abs(stats.retentionPercent - 109.0 / 128.0 * 100) < 0.0001)
    }

    @Test func unstudiedYieldsZeroRates() {
        let stats = HeroTodayStats()
        #expect(stats.paceSecondsPerCard == 0)
        #expect(stats.retentionPercent == 0)
        #expect(stats.filledStars == 0)
    }

    @Test func starsFollowOnigiriThresholds() {
        #expect(HeroTodayStats(retentionPassed: 90, retentionTotal: 100).filledStars == 5)
        #expect(HeroTodayStats(retentionPassed: 70, retentionTotal: 100).filledStars == 4)
        #expect(HeroTodayStats(retentionPassed: 50, retentionTotal: 100).filledStars == 3)
        #expect(HeroTodayStats(retentionPassed: 30, retentionTotal: 100).filledStars == 2)
        #expect(HeroTodayStats(retentionPassed: 1, retentionTotal: 100).filledStars == 1)
        #expect(HeroTodayStats(retentionPassed: 0, retentionTotal: 100).filledStars == 1)
        #expect(HeroTodayStats(retentionPassed: 0, retentionTotal: 0).filledStars == 0)
    }
}
