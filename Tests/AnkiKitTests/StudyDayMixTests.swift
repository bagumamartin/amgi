import Testing
@testable import AnkiKit

@Suite("Study day mix derivation")
struct StudyDayMixTests {
    /// The user's own example: yesterday 10 due (4 new, 4 learn,
    /// 2 review); new and learn cleared, 2 review left.
    private static var example: StudyDayMix {
        StudyDayMix(
            answeredNew: 4,
            answeredLearn: 4,
            answeredRelearn: 0,
            answeredReview: 0,
            answeredCards: 8,
            remainingLearn: 0,
            remainingReview: 2
        )
    }

    @Test("due mix splits answered and remaining by state")
    func dueMix() {
        let mix = Self.example
        #expect(mix.dueNew == 4)
        #expect(mix.dueLearn == 4)
        #expect(mix.dueReview == 2)
        #expect(mix.dueTotal == 10)
    }

    @Test("remaining and progress track the unanswered remainder")
    func remainingAndProgress() {
        let mix = Self.example
        #expect(mix.remainingTotal == 2)
        #expect(mix.progressFraction == 0.8)
    }

    @Test("relearn folds into learn")
    func relearnFoldsIntoLearn() {
        let mix = StudyDayMix(
            answeredNew: 0,
            answeredLearn: 3,
            answeredRelearn: 2,
            answeredReview: 5,
            answeredCards: 10,
            remainingLearn: 1,
            remainingReview: 0
        )
        #expect(mix.answeredLearnTotal == 5)
        #expect(mix.dueLearn == 6)
        #expect(mix.dueTotal == 11)
    }

    @Test("empty span reads zero without dividing")
    func emptySpan() {
        let mix = StudyDayMix(
            answeredNew: 0,
            answeredLearn: 0,
            answeredRelearn: 0,
            answeredReview: 0,
            answeredCards: 0,
            remainingLearn: 0,
            remainingReview: 0
        )
        #expect(mix.dueTotal == 0)
        #expect(mix.progressFraction == 0)
    }

    @Test("closed day reads full progress")
    func closedDay() {
        let mix = StudyDayMix(
            answeredNew: 2,
            answeredLearn: 3,
            answeredRelearn: 0,
            answeredReview: 5,
            answeredCards: 10,
            remainingLearn: 0,
            remainingReview: 0
        )
        #expect(mix.progressFraction == 1)
    }

    @Test("negative inputs clamp instead of corrupting totals")
    func negativeClamp() {
        let mix = StudyDayMix(
            answeredNew: -1,
            answeredLearn: 0,
            answeredRelearn: 0,
            answeredReview: 0,
            answeredCards: 0,
            remainingLearn: -2,
            remainingReview: 0
        )
        #expect(mix.dueTotal == 0)
        #expect(mix.remainingTotal == 0)
        #expect(mix.progressFraction == 0)
    }
}
