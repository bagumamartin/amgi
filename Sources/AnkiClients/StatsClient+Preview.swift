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
        studyLedger: { _, _, days, detailOffset in
            StudyLedger(days: days.map { window in
                StudyLedger.Day(
                    offset: window.offset,
                    due: .init(new: 20, learn: 6, review: 84),
                    studied: .init(new: 20, learn: 4, review: 61, cards: 85, answers: 112, millis: 2_640_000),
                    left: .init(new: 0, learn: 2, review: 23),
                    detail: window.offset == detailOffset
                        ? .init(leftLearningIds: [1, 2], leftReviewIds: Array(3...25))
                        : nil
                )
            })
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
