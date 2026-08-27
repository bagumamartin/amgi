// AmgiApp/Sources/Shared/WidgetSnapshot.swift
import Foundation

public struct WidgetSnapshot: Codable, Sendable {
    public var deckId: Int64
    public var deckName: String
    public var newCount: Int
    public var learnCount: Int
    public var reviewCount: Int
    /// Answers given today (engine revlog, already rollover-aware). Kept as
    /// an FYI stat — NOT the progress numerator, because re-answers would
    /// inflate it (see `completedToday`).
    public var reviewedToday: Int
    /// Cards graduated past today's Anki-day scope — the SAME quantity the
    /// reviewer's daily progress bar counts (`dailyCompletedToday`):
    /// `is:review rated:1` in scope. Re-answers (Again, mid-step learning)
    /// don't count, so widget and study screen agree.
    public var completedToday: Int
    public var streak: Int
    public var lastSevenDays: [Int]   // index 0 = 6 days ago, index 6 = today
    public var snapshotDate: Date
    /// When the current Anki day ends (rollover hour from settings, NOT
    /// calendar midnight). The widget schedules its day-rollover timeline
    /// entry here — the engine computes "today", so the widget must not
    /// assume 00:00.
    public var nextDayStart: Date?

    public var totalDue: Int { newCount + learnCount + reviewCount }

    /// Fraction of today's work done — mirrors the reviewer's
    /// `DailyProgressBar`: completed / (completed + live remaining). Live
    /// denominator keeps the bar honest (can't read 100% while cards are
    /// still due, self-corrects when cards appear mid-day).
    public var todayProgressFraction: Double {
        let total = max(completedToday + totalDue, 1)
        return min(1.0, Double(max(completedToday, 0)) / Double(total))
    }

    public init(
        deckId: Int64,
        deckName: String,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        reviewedToday: Int,
        completedToday: Int,
        streak: Int,
        lastSevenDays: [Int],
        snapshotDate: Date,
        nextDayStart: Date? = nil
    ) {
        self.deckId = deckId
        self.deckName = deckName
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.reviewedToday = reviewedToday
        self.completedToday = completedToday
        self.streak = streak
        self.lastSevenDays = lastSevenDays
        self.snapshotDate = snapshotDate
        self.nextDayStart = nextDayStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deckId = try container.decode(Int64.self, forKey: .deckId)
        deckName = try container.decode(String.self, forKey: .deckName)
        newCount = try container.decode(Int.self, forKey: .newCount)
        learnCount = try container.decode(Int.self, forKey: .learnCount)
        reviewCount = try container.decode(Int.self, forKey: .reviewCount)
        reviewedToday = try container.decode(Int.self, forKey: .reviewedToday)
        // Pre-graduation snapshots only had the answer count; it's the
        // closest available approximation until the app writes fresh data.
        completedToday = try container.decodeIfPresent(Int.self, forKey: .completedToday)
            ?? reviewedToday
        streak = try container.decode(Int.self, forKey: .streak)
        lastSevenDays = try container.decode([Int].self, forKey: .lastSevenDays)
        snapshotDate = try container.decode(Date.self, forKey: .snapshotDate)
        nextDayStart = try container.decodeIfPresent(Date.self, forKey: .nextDayStart)
    }

    /// Runtime fallback used when the app has not written a shared snapshot
    /// yet. It deliberately contains no fabricated counts; hardcoded sample
    /// data belongs only to WidgetKit previews.
    public static var empty: WidgetSnapshot {
        WidgetSnapshot(
            deckId: 0,
            deckName: "Open Amgi to refresh",
            newCount: 0,
            learnCount: 0,
            reviewCount: 0,
            reviewedToday: 0,
            completedToday: 0,
            streak: 0,
            lastSevenDays: Array(repeating: 0, count: 7),
            snapshotDate: .distantPast
        )
    }

    public static var placeholder: WidgetSnapshot {
        WidgetSnapshot(
            deckId: 0,
            deckName: "All Decks",
            newCount: 5,
            learnCount: 8,
            reviewCount: 22,
            reviewedToday: 18,
            completedToday: 18,
            streak: 7,
            lastSevenDays: [20, 15, 22, 18, 25, 12, 8],
            snapshotDate: Date()
        )
    }
}
