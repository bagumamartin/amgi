/// Backend-compatible configuration for Anki's Custom Study operation.
public enum CustomStudyRequest: Equatable, Sendable {
    case increaseNewLimit(Int32)
    case increaseReviewLimit(Int32)
    case reviewForgotten(days: UInt32)
    case reviewAhead(days: UInt32)
    case previewNew(days: UInt32)
    case studyByState(
        CustomStudyCardState,
        limit: UInt32,
        includeTags: [String],
        excludeTags: [String]
    )
}

public enum CustomStudyCardState: String, CaseIterable, Equatable, Sendable {
    case new
    case due
    case review
    case all
}

public struct CustomStudyTag: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let isIncluded: Bool
    public let isExcluded: Bool

    public init(name: String, isIncluded: Bool = false, isExcluded: Bool = false) {
        self.name = name
        self.isIncluded = isIncluded
        self.isExcluded = isExcluded
    }
}

public struct CustomStudyDefaults: Equatable, Sendable {
    public let tags: [CustomStudyTag]
    public let extendNew: UInt32
    public let extendReview: UInt32
    public let availableNew: UInt32
    public let availableReview: UInt32
    public let availableNewInChildren: UInt32
    public let availableReviewInChildren: UInt32

    public init(
        tags: [CustomStudyTag],
        extendNew: UInt32,
        extendReview: UInt32,
        availableNew: UInt32,
        availableReview: UInt32,
        availableNewInChildren: UInt32,
        availableReviewInChildren: UInt32
    ) {
        self.tags = tags
        self.extendNew = extendNew
        self.extendReview = extendReview
        self.availableNew = availableNew
        self.availableReview = availableReview
        self.availableNewInChildren = availableNewInChildren
        self.availableReviewInChildren = availableReviewInChildren
    }
}

public struct CustomStudyResult: Equatable, Sendable {
    public let changes: CollectionChanges
    public let sessionDeck: DeckInfo?

    public init(changes: CollectionChanges, sessionDeck: DeckInfo?) {
        self.changes = changes
        self.sessionDeck = sessionDeck
    }
}
