#if DEBUG
import AnkiKit
import Dependencies

extension StatsClient {
    /// Deterministic in-memory client used by SwiftUI `#Preview` blocks.
    /// Returns a fully-populated `GraphsSnapshot` so every chart renders.
    public static let previewValue = StatsClient(
        fetchGraphs: { _, _ in
            GraphsSnapshot.sample
        },
        graduatedToday: { _ in 7 },
        learningDueToday: { _ in 3 },
        lastRating: { _ in nil },
        dayMix: { _, _, _, _ in
            StudyDayMix(
                answeredNew: 5,
                answeredLearn: 8,
                answeredRelearn: 2,
                answeredReview: 20,
                answeredCards: 35,
                remainingLearn: 0,
                remainingReview: 0
            )
        },
        studyHistory: { _, _, _ in
            StudyHistory(learningIds: [1, 2], reviewIds: [3, 4, 5], newCandidateIds: [6, 7], unresolved: [])
        },
        reviewTimes: { _, startMs, _ in
            // A morning and an evening session.
            let hour: Int64 = 3_600_000
            return (0..<12).map { startMs + 5 * hour + $0 * 60_000 }
                + (0..<20).map { startMs + 15 * hour + $0 * 90_000 }
        }
    )
}
#endif
