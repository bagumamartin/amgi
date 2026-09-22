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

    func testSpanSearchesASinglePastDayAndAWeek() {
        XCTAssertEqual(StudySpan.ratedSearch(ease: 1, oldest: 1, newest: 1), "rated:2:1 -rated:1:1")
        XCTAssertEqual(StudySpan.ratedSearch(ease: 4, oldest: 0, newest: 0), "rated:1:4")
        XCTAssertEqual(StudySpan.ratedSearch(ease: nil, oldest: 6, newest: 0), "rated:7")
        XCTAssertEqual(StudySpan.ratedSearch(ease: 1, oldest: 14, newest: 8), "rated:15:1 -rated:8:1")
        XCTAssertEqual(StudySpan.dueSearch(daysAhead: 1), "is:review prop:due=1")
        XCTAssertEqual(
            StudySpan.criterionSearch(ease: nil, extra: "tag:leech", oldest: 1, newest: 1),
            "rated:2 -rated:1 tag:leech"
        )
        XCTAssertEqual(
            StudySpan.criterionSearch(ease: 1, extra: "prop:lapses>=1", oldest: 1, newest: 1),
            "rated:2:1 -rated:1:1 prop:lapses>=1"
        )
        XCTAssertEqual(
            StudySpan.scopedSearch("rated:2 -rated:1", deckFullName: "Korean", includeSubdecks: true),
            "rated:2 -rated:1 deck:\"Korean\""
        )
        XCTAssertEqual(
            StudySpan.scopedSearch("rated:2 -rated:1", deckFullName: "Korean", includeSubdecks: false),
            "rated:2 -rated:1 deck:\"Korean\" -deck:\"Korean::*\""
        )
        XCTAssertEqual(StudySpan.scopedSearch("rated:2", deckFullName: "", includeSubdecks: false), "rated:2")
    }

    func testSpanTitlesAndEmptyCopy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let today = DateComponents(calendar: calendar, year: 2026, month: 9, day: 21).date!
        XCTAssertEqual(StudySpan.dayTitle(offset: 0, day: today, calendar: calendar), "Today")
        XCTAssertEqual(StudySpan.dayTitle(offset: 1, day: today, calendar: calendar), "Yesterday")
        XCTAssertEqual(StudySpan.dayTitle(offset: -1, day: today, calendar: calendar), "Tomorrow")
        let wednesday = calendar.date(byAdding: .day, value: -5, to: today)!
        XCTAssertEqual(StudySpan.dayTitle(offset: 5, day: wednesday, calendar: calendar), "16 Sep")
        XCTAssertEqual(
            StudySpan.subtitle(grain: .day, todayStart: today, anchor: 5, calendar: calendar),
            "Wednesday"
        )
        XCTAssertEqual(StudySpan.monthTitle(todayStart: today, anchor: 0, calendar: calendar), "September")
        XCTAssertEqual(
            StudySpan.emptyCriterionMessage(noun: "leeches", spanName: "Yesterday"),
            "No leeches yesterday"
        )
        XCTAssertEqual(
            StudySpan.emptyCriterionMessage(noun: "Easy ratings", spanName: "September"),
            "No Easy ratings in September"
        )
        XCTAssertEqual(StudySpan.dueEmptyMessage(spanName: "Tomorrow"), "Nothing due tomorrow")
        let rows = StudySpan.ratingRows(
            counts: ["leeches": 3, "easy": 2, "reviewed": 6],
            oldest: 1, newest: 1, spanName: "Yesterday"
        )
        XCTAssertEqual(rows.map(\.id), StudySpan.criteria.map(\.id))
        XCTAssertEqual(rows.first?.count, 3)
        XCTAssertEqual(rows.first?.search, "rated:2 -rated:1 tag:leech")
        XCTAssertEqual(rows.first?.reschedulesByDefault, true)
        XCTAssertEqual(rows.first { $0.id == "easy" }?.reschedulesByDefault, false)
        XCTAssertEqual(rows.first { $0.id == "solid" }?.reschedulesByDefault, false)
        XCTAssertEqual(rows.last?.count, 6)
        XCTAssertEqual(rows.last?.title, "All reviewed")
    }

    func testWeekContainingAKnownMonday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        let monday = DateComponents(calendar: calendar, year: 2026, month: 9, day: 21).date!
        let offsets = StudySpan.weekOffsets(todayStart: monday, anchor: 0, calendar: calendar)
        XCTAssertEqual(offsets, [0, -1, -2, -3, -4, -5, -6])
        let yesterdayWeek = StudySpan.weekOffsets(todayStart: monday, anchor: 1, calendar: calendar)
        XCTAssertEqual(yesterdayWeek, [7, 6, 5, 4, 3, 2, 1])
    }

    func testStudiedDurationSpellsHoursPastSixtyMinutes() {
        XCTAssertNil(StudySpan.studiedDuration(minutes: 0))
        XCTAssertEqual(StudySpan.studiedDuration(minutes: 45), "45 min")
        XCTAssertEqual(StudySpan.studiedDuration(minutes: 60), "1 hour")
        XCTAssertEqual(StudySpan.studiedDuration(minutes: 61), "1 hour 1 minute")
        XCTAssertEqual(StudySpan.studiedDuration(minutes: 83), "1 hour 23 minutes")
        XCTAssertEqual(StudySpan.studiedDuration(minutes: 120), "2 hours")
    }

    func testYearWallAndJumpTargets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        let monday = DateComponents(calendar: calendar, year: 2026, month: 9, day: 21).date!
        XCTAssertEqual(StudySpan.pastLimit, 365 * 5)
        XCTAssertEqual(StudySpan.title(grain: .year, todayStart: monday, anchor: 0, calendar: calendar), "2026")
        XCTAssertTrue(StudySpan.isCurrent(grain: .year, todayStart: monday, anchor: 0, calendar: calendar))
        XCTAssertFalse(StudySpan.isCurrent(grain: .year, todayStart: monday, anchor: 400, calendar: calendar))
        XCTAssertEqual(StudySpan.jumpTitle(grain: .day), "Today")
        XCTAssertEqual(StudySpan.jumpTitle(grain: .week), "This week")
        XCTAssertEqual(StudySpan.jumpTitle(grain: .month), "This month")
        XCTAssertEqual(StudySpan.jumpTitle(grain: .year), "This year")

        let wall = StudySpan.yearChart(todayStart: monday, anchor: 0, calendar: calendar) { offset in
            if offset == 0 { return 8 }
            if offset == -1 { return 3 }
            return 0
        }
        XCTAssertEqual(wall.year, 2026)
        XCTAssertTrue(wall.isCurrentYear)
        XCTAssertEqual(wall.months.count, 12)
        let september = wall.months[8]
        XCTAssertEqual(september.name, "Sep")
        XCTAssertTrue(september.isCurrent)
        XCTAssertFalse(wall.months[0].isCurrent)
        let today = september.cells.first { $0.isToday }
        XCTAssertEqual(today?.dayNumber, "21")
        XCTAssertEqual(today?.value, 8)
        let tomorrow = september.cells.first { $0.offset == -1 }
        XCTAssertEqual(tomorrow?.value, 3)
        XCTAssertEqual(tomorrow?.isFuture, true)
        let days = StudySpan.yearDayOffsets(todayStart: monday, anchor: 0, calendar: calendar)
        XCTAssertEqual(days.count, 365)
        XCTAssertTrue(days.contains(0))
    }

    func testRolloverDoesNotDuplicateACalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        let todayStart = DateComponents(calendar: calendar, year: 2026, month: 9, day: 22, hour: 4).date!
        let offsets = StudySpan.monthOffsets(todayStart: todayStart, anchor: 0, calendar: calendar)
        let numbers = offsets.compactMap { offset -> Int? in
            guard let offset else { return nil }
            let day = StudySpan.date(todayStart: todayStart, offset: offset, calendar: calendar)
            return calendar.component(.day, from: day)
        }
        XCTAssertEqual(numbers.count, 30)
        XCTAssertEqual(numbers.filter { $0 == 22 }.count, 1)
        XCTAssertEqual(numbers[21], 22)
        XCTAssertEqual(numbers[22], 23)
    }

    func testAnkiDayHoursStartAtRollover() {
        XCTAssertEqual(StudySpan.ankiDayClockHour(rolloverHour: 4, slot: 0), 4)
        XCTAssertEqual(StudySpan.ankiDayClockHour(rolloverHour: 4, slot: 6), 10)
        XCTAssertEqual(StudySpan.ankiDayClockHour(rolloverHour: 4, slot: 20), 0)
        XCTAssertEqual(StudySpan.hourLabel(4), "4am")
        XCTAssertEqual(StudySpan.hourLabel(0), "12am")
        XCTAssertEqual(StudySpan.hourLabel(22), "10pm")
        XCTAssertEqual(StudySpan.hourLabel(StudySpan.ankiDayClockHour(rolloverHour: 0, slot: 18)), "6pm")
        XCTAssertEqual(StudySpan.hourLabel(16, twentyFourHour: true), "16")
        XCTAssertEqual(StudySpan.hourColumnLabel(4, twentyFourHour: false), "4a")
        XCTAssertEqual(StudySpan.hourColumnLabel(0, twentyFourHour: false), "12a")
        XCTAssertEqual(StudySpan.hourColumnLabel(22, twentyFourHour: false), "10p")
        XCTAssertEqual(StudySpan.hourColumnLabel(16, twentyFourHour: true), "16")
        let marks = StudySpan.dayAxisMarks(rolloverHour: 4)
        XCTAssertEqual(marks.map(\.title), ["Morning", "Noon", "Evening", "Midnight"])
        XCTAssertEqual(marks.map(\.slot), [2, 8, 14, 20])
        XCTAssertEqual(StudySpan.uses24HourClock(locale: Locale(identifier: "en_US")), false)
        XCTAssertEqual(StudySpan.uses24HourClock(locale: Locale(identifier: "hu_HU")), true)
    }

    func testSpanSubtitlesFollowTheGrain() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = DateComponents(calendar: calendar, year: 2026, month: 9, day: 21).date!
        XCTAssertEqual(
            StudySpan.subtitle(grain: .week, todayStart: today, anchor: 0, calendar: calendar),
            "Week 39"
        )
        XCTAssertEqual(
            StudySpan.subtitle(grain: .month, todayStart: today, anchor: 0, calendar: calendar),
            "Autumn"
        )
        XCTAssertEqual(
            StudySpan.subtitle(grain: .year, todayStart: today, anchor: 0, calendar: calendar),
            "Common year"
        )
        let leap = DateComponents(calendar: calendar, year: 2024, month: 2, day: 1).date!
        XCTAssertEqual(
            StudySpan.subtitle(grain: .year, todayStart: leap, anchor: 0, calendar: calendar),
            "Leap year"
        )
        XCTAssertFalse(StudySpan.isLeapYear(1900))
        XCTAssertTrue(StudySpan.isLeapYear(2000))

        var australia = calendar
        australia.locale = Locale(identifier: "en_AU")
        australia.timeZone = TimeZone(identifier: "Australia/Sydney")!
        XCTAssertEqual(StudySpan.seasonName(month: 9, calendar: australia), "Spring")
        XCTAssertEqual(StudySpan.seasonName(month: 1, calendar: australia), "Summer")
        var unitedStates = calendar
        unitedStates.locale = Locale(identifier: "en_US")
        XCTAssertEqual(StudySpan.seasonName(month: 9, calendar: unitedStates), "Fall")
        var budapest = calendar
        budapest.timeZone = TimeZone(identifier: "Europe/Budapest")!
        XCTAssertFalse(StudySpan.isSouthernHemisphere(locale: Locale(identifier: "hu_HU"), timeZone: budapest.timeZone))
        XCTAssertTrue(
            StudySpan.isSouthernHemisphere(
                locale: Locale(identifier: "en_US"),
                timeZone: TimeZone(identifier: "Australia/Sydney")!
            )
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
