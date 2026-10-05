import Foundation

/// The complete decision queue. The focused ID is presentation state, so
/// enrichment can update the evidence without changing the question mid-read.
public struct DeckTriageData: Equatable, Hashable, Sendable {
    public enum Readiness: Equatable, Hashable, Sendable { case loading, ready, unavailable }
    public let items: [DeckTriageItem]
    public let readiness: Readiness
    public let focusedID: Int64?
    public let busyID: Int64?
    public let errorMessage: String?
    /// Fully paused decks are not automatic decisions, but their manual
    /// review entry belongs in this card so the Library keeps one clear
    /// decision surface instead of a detached link.
    public let manualReviewCount: Int

    public init(items: [DeckTriageItem], readiness: Readiness = .ready,
                focusedID: Int64? = nil, busyID: Int64? = nil, errorMessage: String? = nil,
                manualReviewCount: Int = 0) {
        self.items = items
        self.readiness = readiness
        self.focusedID = focusedID
        self.busyID = busyID
        self.errorMessage = errorMessage
        self.manualReviewCount = manualReviewCount
    }

    public init(items: [DeckTriageItem], isResolved: Bool) {
        self.init(items: items, readiness: isResolved ? .ready : .loading)
    }

    public static let unresolved = DeckTriageData(items: [], readiness: .loading)
    public static let resolvedEmpty = DeckTriageData(items: [])
    public var isResolved: Bool { readiness == .ready }
    public var isHidden: Bool {
        manualReviewCount == 0 && (readiness == .unavailable || (isResolved && items.isEmpty))
    }
    public var focusedItem: DeckTriageItem? {
        items.first { $0.id == focusedID } ?? items.first
    }
}

/// Strings are supplied by DecksFeature using the app's localization catalog;
/// sample defaults keep the engine-free UI previews useful in isolation.
public struct DeckTriageItem: Equatable, Hashable, Sendable, Identifiable {
    public let row: DeckRowViewData
    public let issue: DeckTriageIssue
    public let question: String
    public let evidence: String
    public let canResumeDirectly: Bool
    public let actions: [DeckTriageAction]
    public var id: Int64 { row.id }
    public var subtitle: String { evidence }

    public init(row: DeckRowViewData, issue: DeckTriageIssue,
                question: String? = nil, evidence: String? = nil, canResumeDirectly: Bool = false,
                actions: [DeckTriageAction]? = nil) {
        self.row = row
        self.issue = issue
        self.canResumeDirectly = canResumeDirectly
        self.question = question ?? Self.sampleQuestion(issue)
        self.evidence = evidence ?? Self.sampleEvidence(row, issue)
        self.actions = actions ?? Self.sampleActions(row: row, issue: issue, canResume: canResumeDirectly)
    }

    private static func sampleActions(row: DeckRowViewData, issue: DeckTriageIssue, canResume: Bool) -> [DeckTriageAction] {
        let study: DeckTriageAction = row.totalCount > 0 ? .study : .pace
        switch issue {
        case .neglected, .neverStarted: return row.id == 1 ? [study] : [study, .pause]
        case .newBacklog: return [.pace, .keepPace]
        case .empty: return row.id == 1 ? [.addCards] : [.addCards, .delete]
        case .parked: return [canResume ? .resume : .chooseCards, .keepPaused]
        }
    }

    private static func sampleQuestion(_ issue: DeckTriageIssue) -> String {
        switch issue {
        case .neglected: "Still want to study this deck?"
        case .neverStarted: "Ready to start this deck?"
        case .newBacklog: "Does this study pace still suit you?"
        case .empty: "What would you like to do with this deck?"
        case .parked: "Ready to bring this deck back?"
        }
    }

    private static func sampleEvidence(_ row: DeckRowViewData, _ issue: DeckTriageIssue) -> String {
        switch issue {
        case .neglected(let days):
            let activity = days.map { "Last studied \($0) days ago" } ?? "No study activity in the past year"
            return "\(activity) · \(row.waitingCount ?? row.totalCount) cards waiting"
        case .neverStarted: return "\(row.availableNewCount ?? row.newCount) new cards waiting"
        case .newBacklog(let perDay, let days):
            return "\(row.availableNewCount ?? row.newCount) new cards · about \(days) days to introduce at \(perDay)/day"
        case .empty: return "No cards, including subdecks"
        case .parked: return "All cards suspended"
        }
    }
}

public enum DeckTriageAction: String, Equatable, Hashable, Sendable {
    case study, pause, pace, keepPace, addCards, delete, resume, chooseCards, keepPaused, deferDecision, viewDeck
}

public enum DeckTriageIssue: Equatable, Hashable, Sendable {
    case neglected(daysAgo: Int?)
    /// All available cards are new and there is no activity in the history window.
    /// This does not make a claim about lifetime review history.
    case neverStarted
    case newBacklog(perDay: Int, daysToClear: Int)
    case empty
    case parked

    public var key: String {
        switch self {
        case .neglected: "inactive"
        case .neverStarted: "unused"
        case .newBacklog: "backlog"
        case .empty: "empty"
        case .parked: "paused"
        }
    }
}

#if DEBUG
public extension DeckTriageData {
    static let sample = DeckTriageData(items: [
        DeckTriageItem(row: DeckRowViewData(id: 11, name: "한국어", fullName: "Languages::한국어",
            newCount: 12, learnCount: 8, reviewCount: 42, isFiltered: false, subdeckCount: 2,
            cardCount: 600, availableNewCount: 12, waitingCount: 62), issue: .neglected(daysAgo: 47)),
        DeckTriageItem(row: DeckRowViewData(id: 12, name: "TOPIK", fullName: "TOPIK",
            newCount: 20, learnCount: 0, reviewCount: 0, isFiltered: false, subdeckCount: 0,
            cardCount: 340, availableNewCount: 340, waitingCount: 340), issue: .neverStarted),
        DeckTriageItem(row: DeckRowViewData(id: 13, name: "Anatomy", fullName: "Anatomy",
            newCount: 20, learnCount: 5, reviewCount: 30, isFiltered: false, subdeckCount: 0,
            cardCount: 900, availableNewCount: 412, waitingCount: 447), issue: .newBacklog(perDay: 20, daysToClear: 21))
    ])
}
#endif
