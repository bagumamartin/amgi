// AmgiApp/Sources/Shared/WidgetSnapshot.swift
import Foundation

public struct WidgetSnapshot: Codable, Sendable {
    public var deckId: Int64
    public var deckName: String
    public var newCount: Int
    public var learnCount: Int
    public var reviewCount: Int
    public var reviewedToday: Int
    /// Cards due + already reviewed today, frozen at the first snapshot of
    /// each calendar day. Drives the large-widget progress bar denominator.
    public var dueBaselineToday: Int
    public var streak: Int
    public var lastSevenDays: [Int]   // index 0 = 6 days ago, index 6 = today
    public var snapshotDate: Date

    public var totalDue: Int { newCount + learnCount + reviewCount }

    /// Fraction of today's baseline completed. Clamped to 1 when re-learning
    /// pushes reviewedToday past the morning baseline.
    public var todayProgressFraction: Double {
        let baseline = max(dueBaselineToday, 1)
        return min(1.0, Double(reviewedToday) / Double(baseline))
    }

    public init(
        deckId: Int64,
        deckName: String,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        reviewedToday: Int,
        dueBaselineToday: Int,
        streak: Int,
        lastSevenDays: [Int],
        snapshotDate: Date
    ) {
        self.deckId = deckId
        self.deckName = deckName
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.reviewedToday = reviewedToday
        self.dueBaselineToday = dueBaselineToday
        self.streak = streak
        self.lastSevenDays = lastSevenDays
        self.snapshotDate = snapshotDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deckId = try container.decode(Int64.self, forKey: .deckId)
        deckName = try container.decode(String.self, forKey: .deckName)
        newCount = try container.decode(Int.self, forKey: .newCount)
        learnCount = try container.decode(Int.self, forKey: .learnCount)
        reviewCount = try container.decode(Int.self, forKey: .reviewCount)
        reviewedToday = try container.decode(Int.self, forKey: .reviewedToday)
        streak = try container.decode(Int.self, forKey: .streak)
        lastSevenDays = try container.decode([Int].self, forKey: .lastSevenDays)
        snapshotDate = try container.decode(Date.self, forKey: .snapshotDate)
        let totalDue = newCount + learnCount + reviewCount
        dueBaselineToday = try container.decodeIfPresent(Int.self, forKey: .dueBaselineToday)
            ?? max(reviewedToday + totalDue, 1)
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
            dueBaselineToday: 1,
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
            dueBaselineToday: 53,
            streak: 7,
            lastSevenDays: [20, 15, 22, 18, 25, 12, 8],
            snapshotDate: Date()
        )
    }
}
