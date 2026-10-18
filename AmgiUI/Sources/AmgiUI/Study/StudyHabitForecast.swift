public import Foundation

/// When in the day a future day's scheduled cards are likely to be studied.
///
/// The scheduler already knows how many cards fall due each day; what it
/// can't know is the hour. That is habit, so the shape comes from past
/// answers: each one adds weight to its clock hour, recent days count more
/// (14-day half-life), and days on the target's weekday count double. The
/// scheduled total is spread over that profile, so the bars always add up
/// to the day's due count.
public enum StudyHabitForecast {
    public static let historyDays = 28
    static let halfLifeDays = 14.0
    static let sameWeekdayWeight = 2.0

    /// Predicted cards per clock hour (index 0 = midnight). All zeros when
    /// nothing is scheduled or there is no history to shape it.
    public static func hourly(
        answeredAtMs history: [Int64],
        scheduled: Int,
        targetDayStart: Date,
        todayStart: Date,
        rolloverHour: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        guard scheduled > 0 else { return Array(repeating: 0, count: 24) }
        let targetWeekday = calendar.component(.weekday, from: targetDayStart)
        let today = ankiDay(todayStart, rolloverHour: rolloverHour, calendar: calendar)

        var weights = Array(repeating: 0.0, count: 24)
        for ms in history {
            let date = Date(timeIntervalSince1970: Double(ms) / 1_000)
            let day = ankiDay(date, rolloverHour: rolloverHour, calendar: calendar)
            let age = max(0, calendar.dateComponents([.day], from: day, to: today).day ?? 0)
            var weight = pow(0.5, Double(age) / halfLifeDays)
            if calendar.component(.weekday, from: day) == targetWeekday { weight *= sameWeekdayWeight }
            weights[calendar.component(.hour, from: date)] += weight
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return Array(repeating: 0, count: 24) }
        return apportion(scheduled, shares: weights.map { $0 / total })
    }

    /// Largest-remainder rounding, so the hours sum exactly to `total`.
    static func apportion(_ total: Int, shares: [Double]) -> [Int] {
        let exact = shares.map { $0 * Double(total) }
        var counts = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { exact[$0] - Double(counts[$0]) > exact[$1] - Double(counts[$1]) }
        for index in order.prefix(max(0, total - counts.reduce(0, +))) {
            counts[index] += 1
        }
        return counts
    }

    /// Calendar date of the Anki day containing `date`.
    private static func ankiDay(_ date: Date, rolloverHour: Int, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-Double(rolloverHour) * 3_600))
    }
}
