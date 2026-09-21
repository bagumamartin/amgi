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

    func testDuePhaseStartsAndEstimatesFromFallbackPace() {
        let summary = StudySummaryData(
            totalDue: 30, newCount: 0, learnCount: 10, reviewCount: 20,
            todayLabel: "Today", subtitleLabel: "", deckCount: 2
        )
        XCTAssertEqual(summary.phase, .due)
        XCTAssertEqual(summary.primaryActionTitle, "Start · 30")
        XCTAssertEqual(summary.sessionShape, "Learning first, then reviews")
        // 30 cards × 8s = 4 minutes.
        XCTAssertEqual(summary.estimateLabel, "About 4 min")
        XCTAssertEqual(
            StudySummaryData.estimatedMinutes(remaining: 30, answerCount: 0, answerMillis: 0),
            4
        )
    }

    func testLeftoverUsesMeasuredPace() {
        let summary = StudySummaryData(
            totalDue: 10, newCount: 10, learnCount: 0, reviewCount: 0,
            todayLabel: "Today", subtitleLabel: "", deckCount: 1,
            reviewedToday: 5, answerCount: 20, answerMillis: 120_000
        )
        XCTAssertEqual(summary.phase, .leftover)
        XCTAssertEqual(summary.primaryActionTitle, "Continue · 10 left")
        XCTAssertEqual(summary.sessionShape, "New cards")
        // 6s per card × 10 = 1 minute.
        XCTAssertEqual(summary.estimateLabel, "About 1 min")
    }

    func testCaughtUpHasNoPlayAction() {
        let quiet = StudySummaryData(
            totalDue: 0, newCount: 0, learnCount: 0, reviewCount: 0,
            todayLabel: "Today", subtitleLabel: "", deckCount: 0
        )
        XCTAssertEqual(quiet.phase, .caughtUp)
        XCTAssertNil(quiet.primaryActionTitle)
        XCTAssertEqual(quiet.caughtUpTitle, "Nothing due today")
        XCTAssertNil(quiet.tomorrowLabel)

        let returning = StudySummaryData(
            totalDue: 0, newCount: 0, learnCount: 0, reviewCount: 0,
            todayLabel: "Today", subtitleLabel: "", deckCount: 0,
            reviewedToday: 12, learningReturning: 1, tomorrowDue: 0
        )
        XCTAssertEqual(returning.caughtUpTitle, "Done for now")
        XCTAssertEqual(returning.returningNote, "1 learning card returns later today")
        XCTAssertNil(returning.tomorrowLabel)
        XCTAssertNil(returning.estimateLabel)
    }

    func testUnderAMinuteEstimate() {
        let summary = StudySummaryData(
            totalDue: 2, newCount: 0, learnCount: 0, reviewCount: 2,
            todayLabel: "Today", subtitleLabel: "", deckCount: 1,
            answerCount: 10, answerMillis: 10_000
        )
        XCTAssertEqual(summary.estimateLabel, "Under a minute")
        XCTAssertEqual(summary.sessionShape, "Reviews")
    }

    func testKeepGoingSearches() {
        XCTAssertEqual(StudyKeepGoing.forgotten.search, "rated:1:1")
        XCTAssertEqual(StudyKeepGoing.ahead.search, "is:review prop:due<=1")
        XCTAssertEqual(StudyKeepGoing.previewNew.search, "is:new")
        XCTAssertFalse(StudyKeepGoing.previewNew.reschedule)
        XCTAssertTrue(StudyKeepGoing.forgotten.reschedule)
        XCTAssertTrue(StudyKeepGoing.ahead.reschedule)
        XCTAssertEqual(StudyKeepGoing.actions.map(\.deckName).count, 3)
        XCTAssertEqual(
            Set(StudyKeepGoing.actions.map(\.deckName)).count,
            3
        )
    }

    func testBacklogNote() {
        XCTAssertEqual(
            StudySummaryData.backlogNote(haveBacklog: true),
            "Daily limits are holding reviews back"
        )
        XCTAssertNil(StudySummaryData.backlogNote(haveBacklog: false))
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
