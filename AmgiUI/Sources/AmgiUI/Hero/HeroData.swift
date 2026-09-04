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

    public init(totalDue: Int, deckCount: Int, streak: Int, recentDayTotals: [Int]) {
        self.totalDue = totalDue
        self.deckCount = deckCount
        self.streak = streak
        self.recentDayTotals = recentDayTotals
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
