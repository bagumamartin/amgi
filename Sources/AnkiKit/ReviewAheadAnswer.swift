public import Foundation

/// A card's first review in a window, with the answer before it — enough to
/// tell which Anki day the card was scheduled for (anki-bridge-rs
/// `review_ahead.rs`). The caller does the day math, in its own calendar.
public struct ReviewAheadAnswer: Equatable, Sendable, Codable {
    public var answeredAtMs: Int64
    public var previousAnswerMs: Int64
    /// Days the previous answer scheduled the card for.
    public var intervalDays: Int

    public init(answeredAtMs: Int64, previousAnswerMs: Int64, intervalDays: Int) {
        self.answeredAtMs = answeredAtMs
        self.previousAnswerMs = previousAnswerMs
        self.intervalDays = intervalDays
    }

    /// Anki days after the answer's own day that the card was due: positive
    /// means it was reviewed ahead of schedule.
    public func daysAhead(rolloverHour: Int, calendar: Calendar = .current) -> Int {
        func dayStart(_ ms: Int64) -> Date {
            let date = Date(timeIntervalSince1970: Double(ms) / 1_000)
            let sameDay = calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: date) ?? date
            if sameDay <= date { return sameDay }
            let before = calendar.date(byAdding: .day, value: -1, to: date) ?? date
            return calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: before) ?? date
        }
        let previousDay = dayStart(previousAnswerMs)
        let due = calendar.date(byAdding: .day, value: intervalDays, to: previousDay) ?? previousDay
        return calendar.dateComponents([.day], from: dayStart(answeredAtMs), to: due).day ?? 0
    }
}
