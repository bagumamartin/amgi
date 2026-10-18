import Foundation
import Testing
@testable import AnkiKit

@Suite("ReviewAheadAnswer")
struct ReviewAheadAnswerTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func ms(_ day: Int, _ hour: Int) -> Int64 {
        let date = DateComponents(calendar: calendar, year: 2026, month: 10, day: day, hour: hour).date!
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    @Test func dueDayComesFromThePreviousAnswersAnkiDay() {
        // Answered 15 Oct at 2 am — still 14 Oct's Anki day — for 6 days:
        // due 20 Oct. Reviewed on 18 Oct, two days early.
        let answer = ReviewAheadAnswer(answeredAtMs: ms(18, 10), previousAnswerMs: ms(15, 2), intervalDays: 6)
        #expect(answer.daysAhead(rolloverHour: 4, calendar: calendar) == 2)
    }

    @Test func onTimeAndOverdueAreNotAhead() {
        let onTime = ReviewAheadAnswer(answeredAtMs: ms(18, 10), previousAnswerMs: ms(15, 12), intervalDays: 3)
        let overdue = ReviewAheadAnswer(answeredAtMs: ms(18, 10), previousAnswerMs: ms(10, 12), intervalDays: 3)
        #expect(onTime.daysAhead(rolloverHour: 4, calendar: calendar) == 0)
        #expect(overdue.daysAhead(rolloverHour: 4, calendar: calendar) < 0)
    }
}
