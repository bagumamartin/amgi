import Testing
import Foundation
import AnkiKit
@testable import AmgiApp

@Suite struct DailyProgressCalculatorTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: 0))!
    }

    // MARK: - ankiDayStart

    @Test func dayStartIsRolloverHourOnSameDayAfterRollover() {
        let now = utcDate(2026, 8, 19, 10, 0)
        let expected = utcDate(2026, 8, 19, 4, 0).timeIntervalSince1970
        #expect(DailyProgressCalculator.ankiDayStart(rolloverHour: 4, now: now, calendar: calendar) == Int64(expected))
    }

    @Test func dayStartIsRolloverHourOnPreviousDayBeforeRollover() {
        let now = utcDate(2026, 8, 19, 2, 0)
        let expected = utcDate(2026, 8, 18, 4, 0).timeIntervalSince1970
        #expect(DailyProgressCalculator.ankiDayStart(rolloverHour: 4, now: now, calendar: calendar) == Int64(expected))
    }

    @Test func midnightRolloverStartsAtMidnight() {
        let now = utcDate(2026, 8, 19, 10, 0)
        let expected = utcDate(2026, 8, 19, 0, 0).timeIntervalSince1970
        #expect(DailyProgressCalculator.ankiDayStart(rolloverHour: 0, now: now, calendar: calendar) == Int64(expected))
    }

    @Test func lateRolloverBelongsToPreviousDayBeforeItPasses() {
        let now = utcDate(2026, 8, 19, 22, 0)
        let expected = utcDate(2026, 8, 18, 23, 0).timeIntervalSince1970
        #expect(DailyProgressCalculator.ankiDayStart(rolloverHour: 23, now: now, calendar: calendar) == Int64(expected))
    }

    // MARK: - secondsUntilNextDayStart

    @Test func nextDayStartAccountsForRollover() {
        // 10am, 4am rollover → next day starts 18h later, not a fixed 24h.
        let now = utcDate(2026, 8, 19, 10, 0)
        #expect(DailyProgressCalculator.secondsUntilNextDayStart(rolloverHour: 4, now: now, calendar: calendar) == 18 * 3600)
    }

    @Test func nextDayStartCanBeHoursAwayWhenRolloverApproaches() {
        // 2am, 4am rollover → only 2h until the next Anki day.
        let now = utcDate(2026, 8, 19, 2, 0)
        #expect(DailyProgressCalculator.secondsUntilNextDayStart(rolloverHour: 4, now: now, calendar: calendar) == 2 * 3600)
    }

    // MARK: - isGraduated

    @Test func wholeDayReviewGraduatesAtOneOrMoreDays() {
        // Review states are day counts; the rollover is already baked in, so
        // ≥ 1 day is a future day regardless of how many seconds remain.
        let secsUntilRollover: UInt32 = 120  // minutes away
        #expect(!DailyProgressCalculator.isGraduated(interval: .days(0), secondsUntilNextDayStart: secsUntilRollover))
        #expect(DailyProgressCalculator.isGraduated(interval: .days(1), secondsUntilNextDayStart: secsUntilRollover))
        #expect(DailyProgressCalculator.isGraduated(interval: .days(7), secondsUntilNextDayStart: secsUntilRollover))
    }

    @Test func subDayStepGraduatesOnlyPastRollover() {
        // A sub-day (learning/relearning) step counts only if its seconds
        // reach past the next rollover — a "day" is not 24h.
        let secsUntilRollover: UInt32 = 2 * 3600
        #expect(!DailyProgressCalculator.isGraduated(interval: .seconds(3_600), secondsUntilNextDayStart: secsUntilRollover))
        #expect(DailyProgressCalculator.isGraduated(interval: .seconds(2 * 3600), secondsUntilNextDayStart: secsUntilRollover))
        #expect(DailyProgressCalculator.isGraduated(interval: .seconds(82_800), secondsUntilNextDayStart: secsUntilRollover))
    }
}
