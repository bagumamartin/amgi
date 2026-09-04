import AnkiClients
import AnkiServices
import AnkiKit
import AppIntents
import Foundation
import SettingsFeature
import SwiftUI

// MARK: - Due count

struct DueCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Due Count"
    static let description = IntentDescription("How many cards are due today, overall or for one deck.")

    @Parameter(title: "Deck", default: nil)
    var deck: DeckEntity?

    /// liveValue resolves through the global dependency registry that
    /// app bootstrap populates — same instance the views use.
    private let deckClient = DeckClient.liveValue

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: IntentDialog
        if let deck {
            guard let deckID = Int64(deck.id) else { throw AppIntentError.invalidDeck }
            let counts = try await deckClient.countsForDeck(DeckID(deckID))
            dialog = "\(deck.name): \(counts.total) due — \(counts.newCount) new, \(counts.learnCount) learning, \(counts.reviewCount) review."
        } else {
            let tree = try await deckClient.fetchTree()
            var total = DeckCounts.zero
            for node in tree {
                total = DeckCounts(
                    newCount: total.newCount + node.counts.newCount,
                    learnCount: total.learnCount + node.counts.learnCount,
                    reviewCount: total.reviewCount + node.counts.reviewCount
                )
            }
            dialog = total.total == 0
                ? "Nothing due — you're all caught up."
                : "\(total.total) due — \(total.newCount) new, \(total.learnCount) learning, \(total.reviewCount) review."
        }
        return .result(dialog: dialog)
    }
}

// MARK: - Start review

struct StartReviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Review"
    static let description = IntentDescription("Opens Amgi and drops you straight into a review session.")
    static let openAppWhenRun = true

    @Parameter(title: "Deck", default: nil)
    var deck: DeckEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            IntentRouter.shared.requestReview(deckID: deck.flatMap { Int64($0.id) }.map { DeckID($0) })
        }
        return .result(dialog: deck.map { "Starting \($0.name)…" } ?? "Starting review…")
    }
}

// MARK: - Quick add

struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Add Card"
    static let description = IntentDescription("Captures a new card into a deck without opening the app.")

    @Parameter(title: "Front", requestValueDialog: "What should the front of the card say?")
    var front: String

    @Parameter(title: "Back", default: nil)
    var back: String?

    @Parameter(title: "Deck", default: nil)
    var deck: DeckEntity?

    private let notesService = NotesService.liveValue
    private let decksService = DecksService.liveValue
    private let notetypesService = NotetypesService.liveValue

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let basic = try notetypesService.getNotetypeNames().first { $0.name == "Basic" }
        guard let notetype = basic else {
            throw AppIntentError.noBasicNotetype
        }
        let targetDeck: DeckInfo
        if let deck, let deckID = Int64(deck.id) {
            targetDeck = DeckInfo(id: DeckID(deckID), name: deck.name)
        } else {
            targetDeck = try decksService.getCurrentDeck()
        }

        var cardTemplate = try notesService.newNote(notetypeId: notetype.id)
        if cardTemplate.fields.indices.contains(1) {
            cardTemplate.fields[0] = front
            cardTemplate.fields[1] = back ?? ""
        }
        try notesService.addNote(template: cardTemplate, deckId: targetDeck.id)
        return .result(dialog: "Card added to \(targetDeck.name).")
    }
}

enum AppIntentError: LocalizedError {
    case noBasicNotetype
    case invalidDeck

    var errorDescription: String? {
        switch self {
        case .noBasicNotetype: return "No 'Basic' notetype found in this collection."
        case .invalidDeck: return "That deck is no longer available."
        }
    }
}

// MARK: - Search

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Searches your collection and reads back the top matches.")

    @Parameter(title: "Query", requestValueDialog: "What are you looking for?")
    var query: String

    private let noteClient = NoteClient.liveValue

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let records = try await noteClient.search(query, 5)
        guard !records.isEmpty else {
            return .result(dialog: "No notes matched “\(query)”.")
        }
        let lines = records.prefix(5).map { "• \($0.sfld)" }.joined(separator: "\n")
        return .result(dialog: IntentDialog(stringLiteral: "\(records.count) match(es):\n\(lines)"))
    }
}

// MARK: - Sync

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Now"
    static let description = IntentDescription("Runs a collection sync with your sync server.")

    private let syncClient = SyncClient.liveValue

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let summary = try await syncClient.sync()
            return .result(dialog: IntentDialog(stringLiteral: "Sync complete — \(String(describing: summary))"))
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: "Sync failed: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Open deck

struct OpenDeckIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Deck"
    static let description = IntentDescription("Opens Amgi on the deck browser for a deck.")
    static let openAppWhenRun = true

    @Parameter(title: "Deck")
    var deck: DeckEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            if let deckID = Int64(deck.id) {
            IntentRouter.shared.requestReview(deckID: DeckID(deckID))
        }
        }
        return .result(dialog: "Opening \(deck.name)…")
    }
}
