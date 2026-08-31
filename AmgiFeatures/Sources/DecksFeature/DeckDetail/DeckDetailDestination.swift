import Foundation
import CasePaths

/// Single source of truth for every modal axis on the deck-detail screen:
/// full-screen review, action sheets, alerts, and the file importer.
@CasePathable
enum DeckDetailDestination {
    case review
    case alert(DeckDetailAlert)
    case sheet(DeckDetailSheet)
    case importer
}

@CasePathable
enum DeckDetailSheet: Identifiable {
    case addNote
    case showDeckOptions
    case exportFile(URL)

    var id: String {
        switch self {
        case .addNote: "addNote"
        case .showDeckOptions: "showDeckOptions"
        case .exportFile(let url): "exportFile-\(url.absoluteString)"
        }
    }
}

@CasePathable
enum DeckDetailAlert {
    case empty
    case error(String)
    case info(String)
    case subdeck
    case extendLimit(DeckLimitKind)
}

/// Which of today's two per-deck caps a custom-study extension raises.
enum DeckLimitKind {
    case new
    case review

    var noun: String {
        switch self {
        case .new: "New"
        case .review: "Review"
        }
    }
}
