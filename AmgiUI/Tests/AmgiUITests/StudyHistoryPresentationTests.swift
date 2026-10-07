import Testing
@testable import AmgiUI

@Suite struct StudyHistoryPresentationTests {
    @Test func candidatesAndUnknownsStayOutsideRemainingCount() {
        let mix = StudyHistoryMix(remainingLearn: 2, remainingReview: 3, newCandidates: 500, unresolved: 8)
        #expect(mix.remainingTotal == 5)
    }

    @Test func historicalReviewKeepsPastMembershipAndCurrentEligibilityDistinct() {
        let review = StudyTimeRow(id: "history", title: "Review", count: 2, search: "cid:1,2", detailTitle: "History", emptyMessage: "Empty", reschedulesByDefault: false, isReconstructed: true, suspensionUnknownCount: 1)
        #expect(review.search == "cid:1,2")
        #expect(review.reviewSearch == "(cid:1,2) -is:suspended -is:buried -deck:filtered")
        #expect(review.isReconstructed)
        #expect(review.suspensionUnknownCount == 1)
        #expect(!review.reschedulesByDefault)
    }
}
