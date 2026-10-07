import Foundation
import Testing
@testable import AnkiKit

@Suite struct StudyHistoryTests {
    @Test func bucketsAreDisjointAndCandidatesDoNotInflateScheduledWork() {
        let history = StudyHistory(
            learningIds: [2, 2, 1, 0], reviewIds: [2, 3, 3, -1], newCandidateIds: [3, 4, 4, 0],
            unresolved: [.init(cardId: 4, reason: .manualSchedule), .init(cardId: 5, reason: .incompleteLog), .init(cardId: 0, reason: .incompleteLog)]
        )
        #expect(history.remainingIds == [1, 2, 3])
        #expect(history.newCandidateIds == [4])
        #expect(history.inspectableIds == [1, 2, 3, 4, 5])
        #expect(StudyHistory.search(ids: history.inspectableIds) == "cid:1,2,3,4,5")
    }

    @Test func emptySelectionNeverOpensTheWholeCollection() {
        #expect(StudyHistory.search(ids: []) == "cid:0")
        #expect(StudyHistory.search(ids: [0, -1]) == "cid:0")
    }

    @Test func decodesBridgeResponseAndReasons() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let history = try decoder.decode(StudyHistory.self, from: Data(#"{"learning_ids":[1,1],"review_ids":[2],"new_candidate_ids":[3],"unresolved":[{"card_id":4,"reason":"learning_rollover"}],"suspension_unknown_ids":[2,2,3,4,9]}"#.utf8))
        #expect(history.remainingIds == [1, 2])
        #expect(history.unresolved.first?.reason == .learningRollover)
        #expect(history.suspensionUnknownIds == [2, 3, 4])
    }

    @Test func largeCandidatePoolHasMatchingCountAndSearch() {
        let ids = Array(Int64(1)...10_001)
        let history = StudyHistory(learningIds: [], reviewIds: [], newCandidateIds: ids, unresolved: [])
        #expect(history.newCandidateIds.count == 10_001)
        #expect(StudyHistory.search(ids: history.newCandidateIds).split(separator: ",").count == 10_001)
    }
}
