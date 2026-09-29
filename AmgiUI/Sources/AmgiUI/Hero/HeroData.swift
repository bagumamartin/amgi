import Foundation

/// Hero-card payload. Anki-agnostic — populated by the container by
/// aggregating from domain models.
public struct HeroData: Equatable, Hashable, Sendable {
    /// Days of review totals the sparkline may draw (oldest → newest).
    /// Compact still shows 14; wider layouts take a trailing slice.
    public static let sparklineCapacity = 90
    /// Bars shown on iPhone; used as the pitch reference on larger screens.
    public static let compactSparklineDays = 14

    public let totalDue: Int
    public let deckCount: Int
    public let streak: Int
    /// Oldest → newest. Length is `sparklineCapacity` (zero-padded).
    public let recentDayTotals: [Int]
    /// Today's review totals. Nil while the review-history fetch is still in
    /// flight — same deal as the heatmap slot in `LibraryListContent`.
    public let today: HeroTodayStats?

    public init(
        totalDue: Int,
        deckCount: Int,
        streak: Int,
        recentDayTotals: [Int],
        today: HeroTodayStats? = nil
    ) {
        self.totalDue = totalDue
        self.deckCount = deckCount
        self.streak = streak
        self.recentDayTotals = recentDayTotals
        self.today = today
    }

    public static let zero = HeroData(
        totalDue: 0,
        deckCount: 0,
        streak: 0,
        recentDayTotals: Array(repeating: 0, count: sparklineCapacity)
    )

    /// Repeating 14-day pattern, long enough for iPad landscape / Mac.
    public static func sampleDayTotals(count: Int = sparklineCapacity) -> [Int] {
        let pattern = [3, 5, 2, 7, 6, 9, 4, 8, 6, 5, 7, 3, 8, 5]
        return (0..<count).map { pattern[$0 % pattern.count] }
    }
}

/// Today's review totals for the hero's stat strip. Same revlog-derived
/// source the desktop stats page (and the Onigiri add-on's Today's Stats)
/// uses: the backend's own today aggregation for studied/time, and Anki's
/// true-retention buckets for the pass rate.
///
/// Retention deliberately follows Anki's true retention (young + mature
/// passed/failed) rather than Onigiri's narrower review-kind-only ratio:
/// it arrives free inside the graphs fetch the hero already performs, it is
/// identical whenever no relearning/day-learning reps occurred today, and it
/// counts lapses — genuine retention failures — instead of hiding them.
/// The percent format and the star ladder below replicate Onigiri exactly.
public struct HeroTodayStats: Equatable, Hashable, Sendable {
    /// All of today's answers (every revlog kind except manual).
    public let studied: Int
    /// Sum of today's revlog durations, milliseconds.
    public let timeMillis: Int
    /// Today's young + mature passed reviews (ease above Again).
    public let retentionPassed: Int
    /// Today's young + mature passed + failed reviews.
    public let retentionTotal: Int

    public init(studied: Int = 0, timeMillis: Int = 0, retentionPassed: Int = 0, retentionTotal: Int = 0) {
        self.studied = studied
        self.timeMillis = timeMillis
        self.retentionPassed = retentionPassed
        self.retentionTotal = retentionTotal
    }

    /// Mean seconds per answer. Zero when nothing was studied.
    public var paceSecondsPerCard: Double {
        guard studied > 0 else { return 0 }
        return Double(timeMillis) / 1_000 / Double(studied)
    }

    /// Pass rate percent, 0...100. Zero when nothing reviewable was studied.
    public var retentionPercent: Double {
        guard retentionTotal > 0 else { return 0 }
        return Double(retentionPassed) / Double(retentionTotal) * 100
    }

    /// Filled stars of five, Onigiri's thresholds verbatim: 90/70/50/30,
    /// with a single participation star once anything was reviewed.
    public var filledStars: Int {
        switch retentionPercent {
        case 90...: 5
        case 70..<90: 4
        case 50..<70: 3
        case 30..<50: 2
        default: retentionTotal > 0 ? 1 : 0
        }
    }

    public static let sample = HeroTodayStats(studied: 128, timeMillis: 2_731_000, retentionPassed: 109, retentionTotal: 128)
}
