import Foundation

/// An interpretation of surviving cards' retained logs at a past Anki-day end.
/// New candidates are the inferred pool, not the historical daily selection.
public struct StudyHistory: Equatable, Sendable, Codable {
    public struct Unresolved: Equatable, Sendable, Codable {
        public let cardId: Int64
        public let reason: Reason

        public enum Reason: String, Codable, Sendable {
            case incompleteLog = "incomplete_log"
            case manualSchedule = "manual_schedule"
            case ambiguousState = "ambiguous_state"
            case learningRollover = "learning_rollover"
        }

        public init(cardId: Int64, reason: Reason) {
            self.cardId = cardId
            self.reason = reason
        }
    }

    public let learningIds: [Int64]
    public let reviewIds: [Int64]
    public let newCandidateIds: [Int64]
    public let unresolved: [Unresolved]
    /// Returned cards whose suspension state at the boundary cannot be dated.
    public let suspensionUnknownIds: [Int64]

    public init(learningIds: [Int64], reviewIds: [Int64], newCandidateIds: [Int64], unresolved: [Unresolved], suspensionUnknownIds: [Int64] = []) {
        self.learningIds = Array(Set(learningIds.filter { $0 > 0 })).sorted()
        self.reviewIds = Array(Set(reviewIds.filter { $0 > 0 }).subtracting(self.learningIds)).sorted()
        self.newCandidateIds = Array(Set(newCandidateIds.filter { $0 > 0 }).subtracting(self.learningIds).subtracting(self.reviewIds)).sorted()
        let known = Set(self.learningIds + self.reviewIds + self.newCandidateIds)
        var seen = known
        self.unresolved = unresolved.filter { $0.cardId > 0 && seen.insert($0.cardId).inserted }.sorted { $0.cardId < $1.cardId }
        let included = known.union(self.unresolved.map(\.cardId))
        self.suspensionUnknownIds = Set(suspensionUnknownIds).intersection(included).sorted()
    }

    public var remainingIds: [Int64] { (learningIds + reviewIds).sorted() }
    public var inspectableIds: [Int64] { (remainingIds + newCandidateIds + unresolved.map(\.cardId)).sorted() }
    /// Numeric IDs only. Never return an empty query, which would browse all cards.
    public static func search(ids: [Int64]) -> String {
        let ids = Set(ids).filter { $0 > 0 }.sorted()
        return ids.isEmpty ? "cid:0" : "cid:" + ids.map(String.init).joined(separator: ",")
    }

    private enum CodingKeys: String, CodingKey {
        case learningIds, reviewIds, newCandidateIds, unresolved, suspensionUnknownIds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            learningIds: try c.decode([Int64].self, forKey: .learningIds),
            reviewIds: try c.decode([Int64].self, forKey: .reviewIds),
            newCandidateIds: try c.decode([Int64].self, forKey: .newCandidateIds),
            unresolved: try c.decode([Unresolved].self, forKey: .unresolved),
            suspensionUnknownIds: try c.decodeIfPresent([Int64].self, forKey: .suspensionUnknownIds) ?? []
        )
    }
}
