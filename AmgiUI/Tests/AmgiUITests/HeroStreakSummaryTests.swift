import Testing
@testable import AmgiUI

@Suite("HeroStreakSummary")
struct HeroStreakSummaryTests {
    @Test func studiedTodayIsActive() {
        let summary = HeroStreakSummary(streak: 4, dayTotals: [0, 0, 3, 1, 2, 5])
        #expect(summary.state == .active)
        #expect(summary.week == [false, false, false, true, true, true, true])
    }

    @Test func milestoneOnlyWhenStudiedToday() {
        #expect(HeroStreakSummary(streak: 7, dayTotals: Array(repeating: 1, count: 7)).state == .milestone)
        #expect(HeroStreakSummary(streak: 7, dayTotals: Array(repeating: 1, count: 7) + [0]).state == .atRisk)
    }

    @Test func liveStreakWithEmptyTodayIsAtRisk() {
        let summary = HeroStreakSummary(streak: 2, dayTotals: [0, 4, 4, 0])
        #expect(summary.state == .atRisk)
        #expect(summary.week.last == false)
    }

    @Test func lapsedReportsDaysSinceLastStudy() {
        let summary = HeroStreakSummary(streak: 0, dayTotals: [2, 0, 0, 0, 0])
        #expect(summary.state == .lapsed(daysAgo: 4))
    }

    @Test func emptyWindowIsFresh() {
        let summary = HeroStreakSummary(streak: 0, dayTotals: Array(repeating: 0, count: 90))
        #expect(summary.state == .fresh)
        #expect(summary.activeDays == 0)
        #expect(summary.week == Array(repeating: false, count: 7))
    }

    @Test func bestIsLongestRunAndNeverBelowStreak() {
        #expect(HeroStreakSummary(streak: 2, dayTotals: [1, 1, 1, 1, 0, 1, 1]).best == 4)
        // The engine may count further back than the loaded window.
        #expect(HeroStreakSummary(streak: 120, dayTotals: Array(repeating: 1, count: 90)).best == 120)
    }

    @Test func shortHistoryPadsTheWeekOnTheLeft() {
        let summary = HeroStreakSummary(streak: 2, dayTotals: [1, 1])
        #expect(summary.week == [false, false, false, false, false, true, true])
    }

    @Test func activeDaysCountsTheLastThirty() {
        let summary = HeroStreakSummary(streak: 0, dayTotals: Array(repeating: 1, count: 60) + Array(repeating: 0, count: 10) + Array(repeating: 1, count: 20) + [0])
        #expect(summary.activeWindow == 30)
        #expect(summary.activeDays == 20)
    }

    @Test func milestoneProgressRunsBetweenMilestones() {
        let summary = HeroStreakSummary(streak: 10, dayTotals: [1])
        #expect(summary.nextMilestone == 14)
        #expect(abs(summary.milestoneProgress - 3.0 / 7.0) < 0.0001)
        #expect(HeroStreakSummary(streak: 2000, dayTotals: [1]).nextMilestone == nil)
    }
}
