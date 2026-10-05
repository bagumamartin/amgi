package import Foundation
package import AnkiKit

/// Pure math for Anki's rollover day and the "graduated past today" rule.
/// Kept dependency-free (apart from AnkiKit's `ScheduledInterval`) so the
/// day-boundary + graduation rules are unit-testable without a backend.
/// `package` (not internal) so `AmgiReviewCore`'s session can apply the same
/// graduation rule the Study ring and widgets use.
package enum DailyProgressCalculator {
    /// Epoch seconds at the start of the current Anki day.
    ///
    /// Anki's day rolls over at `rolloverHour` local time (e.g. 4 for 4am),
    /// not at calendar midnight. Before the rollover hour the current Anki
    /// day still began *yesterday* at that hour.
    package static func ankiDayStart(
        rolloverHour: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int64 {
        let hour = max(0, min(23, rolloverHour))
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        components.second = 0

        let rollover = calendar.date(from: components) ?? now
        let dayStart: Date
        if rollover <= now {
            dayStart = rollover
        } else {
            dayStart = calendar.date(byAdding: .day, value: -1, to: rollover) ?? rollover
        }
        return Int64(dayStart.timeIntervalSince1970)
    }

    /// Seconds from `now` until the *next* Anki day begins. This is not a
    /// fixed 24h — it can be minutes away when the rollover hour is close, or
    /// the better part of a day when it just passed.
    package static func secondsUntilNextDayStart(
        rolloverHour: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UInt32 {
        let todayStart = ankiDayStart(rolloverHour: rolloverHour, now: now, calendar: calendar)
        let today = Date(timeIntervalSince1970: TimeInterval(todayStart))
        // Calendar arithmetic, not `+ 86_400`. An Anki day is a *local*
        // calendar day, and a local day is 23 or 25 hours long across a DST
        // transition — twice a year the fixed addition put the next rollover
        // an hour out. A card due at 23:30 the evening before a spring-forward
        // then failed to count as graduated until 00:30.
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: today) else {
            // Calendar failure: the rollover hour is outside this calendar's
            // valid range. Prefer being an hour early (graduating a card
            // slightly early) over an hour late.
            return UInt32(max(0, 86_400 - (now.timeIntervalSince1970 - TimeInterval(todayStart))))
        }
        return UInt32(max(0, nextDay.timeIntervalSince(now)))
    }

    /// A card counts as "completed" for the day when the chosen rating's next
    /// scheduled review lands on a future Anki day — i.e. after the next
    /// rollover. Review states carry a whole-day count (`days >= 1` is already
    /// rollover-aware); sub-day states carry seconds, so they graduate only
    /// when their seconds reach past the next rollover.
    package static func isGraduated(interval: ScheduledInterval, secondsUntilNextDayStart: UInt32) -> Bool {
        switch interval {
        case .days(let days): return days >= 1
        case .seconds(let secs): return secs >= secondsUntilNextDayStart
        }
    }
}
