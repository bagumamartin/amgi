import XCTest
@testable import AmgiUI

final class StudyViewDataTests: XCTestCase {
    func testProgressFractionClampsToOne() {
        let summary = StudySummaryData(
            totalDue: 0, newCount: 0, learnCount: 0, reviewCount: 0,
            todayLabel: "Today", subtitleLabel: "", deckCount: 0,
            reviewedToday: 130, dueBaselineToday: 100
        )
        XCTAssertEqual(summary.todayProgressFraction, 1.0)
        XCTAssertEqual(summary.todayProgressPercent, 100)
    }

    func testProgressFractionZeroWhenNothingReviewed() {
        let summary = StudySummaryData(
            totalDue: 50, newCount: 10, learnCount: 5, reviewCount: 35,
            todayLabel: "Today", subtitleLabel: "", deckCount: 1,
            reviewedToday: 0, dueBaselineToday: 50
        )
        XCTAssertEqual(summary.todayProgressFraction, 0.0)
    }

    func testProgressFractionPartial() {
        let summary = StudySummaryData(
            totalDue: 50, newCount: 10, learnCount: 5, reviewCount: 35,
            todayLabel: "Today", subtitleLabel: "", deckCount: 1,
            reviewedToday: 25, dueBaselineToday: 100
        )
        XCTAssertEqual(summary.todayProgressFraction, 0.25)
        XCTAssertEqual(summary.todayProgressPercent, 25)
    }

    func testProgressFractionFallsBackToOneBaseline() {
        let summary = StudySummaryData(
            totalDue: 0, newCount: 0, learnCount: 0, reviewCount: 0,
            todayLabel: "Today", subtitleLabel: "", deckCount: 0
        )
        XCTAssertEqual(summary.todayProgressFraction, 0.0)
        XCTAssertEqual(summary.todayProgressPercent, 0)
    }

    func testCardsRemainingToCloseIsBaselineMinusReviewed() {
        let summary = StudySummaryData(
            totalDue: 50, newCount: 10, learnCount: 5, reviewCount: 35,
            todayLabel: "Today", subtitleLabel: "", deckCount: 1,
            reviewedToday: 30, dueBaselineToday: 100
        )
        XCTAssertEqual(summary.cardsRemainingToClose, 70)
    }

    func testCardsRemainingToCloseClampsAtZero() {
        let summary = StudySummaryData(
            totalDue: 0, newCount: 0, learnCount: 0, reviewCount: 0,
            todayLabel: "Today", subtitleLabel: "", deckCount: 0,
            reviewedToday: 130, dueBaselineToday: 100
        )
        XCTAssertEqual(summary.cardsRemainingToClose, 0)
    }
}
