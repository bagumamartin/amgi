import AmgiAppCore
import AmgiAppShared
import AnkiClients
import AnkiKit
import AnkiServices
import AppIntents
import AppIntentsFeature
import Dependencies
import Foundation
import SyncFeature

@MainActor
private struct IntentDependencies {
    @Dependency(\.deckClient) var deckClient
    @Dependency(\.decksService) var decksService
    @Dependency(\.notetypesClient) var notetypesClient
    @Dependency(\.notesService) var notesService
    @Dependency(\.collectionStore) var collectionStore
    @Dependency(\.noteClient) var noteClient
    @Dependency(\.syncCoordinator) var syncCoordinator
}

// MARK: - Due count

struct DueCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Due Count"
    static let description = IntentDescription("How many cards are due today, overall or for one deck.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Deck", default: nil)
    var deck: DeckEntity?

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let profile = AccountStore.shared.selectedContext
        let dependencies = IntentDependencies()
        let deckClient = dependencies.deckClient

        let counts: DeckCounts
        let dialog: IntentDialog
        if let deck {
            let deckID = try deck.resolvedDeckID(currentProfileID: profile.id)
            counts = try await deckClient.countsForDeck(deckID)
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
            counts = total
            dialog = counts.total == 0
                ? "Nothing due — you're all caught up."
                : "\(counts.total) due — \(counts.newCount) new, \(counts.learnCount) learning, \(counts.reviewCount) review."
        }

        try requireUnchangedProfile(profile)
        return .result(value: counts.total, dialog: dialog)
    }
}

// MARK: - Start review

struct StartReviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Review"
    static let description = IntentDescription("Opens Ijuka and drops you into a review session.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Deck", default: nil)
    var deck: DeckEntity?

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = AccountStore.shared.selectedContext
        let deckID = try deck?.resolvedDeckID(currentProfileID: profile.id)
        AppNavigationCoordinator.shared.submit(
            .review(deckID: deckID?.rawValue ?? 0),
            profile: profile
        )
        try requireUnchangedProfile(profile)
        return .result(dialog: deck.map { "Starting \($0.name)…" } ?? "Starting review…")
    }
}

// MARK: - Quick add

struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Add Card"
    static let description = IntentDescription("Captures a new card into a deck without opening Ijuka.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Front", requestValueDialog: "What should the front of the card say?")
    var front: String

    @Parameter(title: "Back", default: nil)
    var back: String?

    @Parameter(title: "Deck", default: nil)
    var deck: DeckEntity?

    @Parameter(title: "Note Type", default: nil)
    var notetype: NotetypeEntity?

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let profile = AccountStore.shared.selectedContext
        let cleanFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFront.isEmpty else { throw AppIntentError.emptyFront }

        let dependencies = IntentDependencies()
        let decksService = dependencies.decksService
        let notetypesClient = dependencies.notetypesClient
        let notesService = dependencies.notesService

        let targetDeck: DeckInfo
        if let deck {
            targetDeck = DeckInfo(
                id: try deck.resolvedDeckID(currentProfileID: profile.id),
                name: deck.name
            )
        } else {
            targetDeck = try decksService.getCurrentDeck()
        }

        let schema: Notetype
        if let notetype {
            schema = try await notetypesClient.get(
                notetype.resolvedNotetypeID(currentProfileID: profile.id)
            )
        } else {
            schema = try await defaultTwoFieldNotetype(using: notetypesClient)
        }

        let frontIndex = min(max(0, schema.config.sortFieldIdx), schema.fields.count - 1)
        guard schema.fields.indices.contains(frontIndex),
              let backIndex = schema.fields.indices.first(where: { $0 != frontIndex })
        else { throw AppIntentError.unsupportedNotetype(schema.name) }

        if #available(iOS 26.0, macOS 26.0, *) {
            try await requestConfirmation(
                actionName: .add,
                dialog: "Add this card to \(targetDeck.name) using \(schema.name)?"
            )
        }

        var template = try notesService.newNote(notetypeId: schema.id)
        guard template.fields.indices.contains(frontIndex),
              template.fields.indices.contains(backIndex)
        else { throw AppIntentError.unsupportedNotetype(schema.name) }
        template.fields[frontIndex] = cleanFront
        template.fields[backIndex] = back?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Confirmation and schema discovery are suspension points. Check the
        // complete runtime profile fence immediately before the synchronous
        // mutation so a switch cannot redirect the write to the new collection.
        try requireUnchangedProfile(profile)
        let creation = try notesService.createNote(template: template, deckId: targetDeck.id)
        try requireUnchangedProfile(profile)

        dependencies.collectionStore.apply(creation.changes, origin: .localUser)
        Task {
            await WidgetRefreshCoordinator.shared.refreshNow()
            await SystemSpotlightIndexer.shared.scheduleDeckRefresh()
        }

        let noteClient = dependencies.noteClient
        let entity: NoteEntity
        if let record = try? await noteClient.fetch(creation.noteID),
           let resolved = NoteEntity(context: profile, note: record) {
            entity = resolved
        } else {
            entity = NoteEntity(
                id: ScopedEntityIdentifier.make(
                    profileID: profile.id,
                    kind: .note,
                    localID: creation.noteID.rawValue
                ),
                title: cleanFront,
                profileID: profile.id,
                profileName: profile.displayName
            )
        }
        try requireUnchangedProfile(profile)

        return .result(
            value: entity.systemSafeEntity(),
            dialog: IntentDialog(
                full: "Added the card to \(targetDeck.name).",
                supporting: "Added"
            )
        )
    }

    private func defaultTwoFieldNotetype(
        using client: NotetypesClient
    ) async throws -> Notetype {
        let summaries = try await client.listAll().sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var normalFallback: Notetype?
        for summary in summaries {
            let schema = try await client.get(summary.id)
            guard schema.config.kind == .normal, schema.fields.count >= 2 else { continue }
            if case .basic = schema.config.originalStockKind { return schema }
            if normalFallback == nil { normalFallback = schema }
        }
        guard let normalFallback else {
            throw AppIntentError.noCompatibleNotetype
        }
        return normalFallback
    }
}

// MARK: - Search

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Searches your collection and returns selectable note results.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Query", requestValueDialog: "What are you looking for?")
    var query: String

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> & ProvidesDialog {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { throw AppIntentError.emptySearch }

        let profile = AccountStore.shared.selectedContext
        let dependencies = IntentDependencies()
        let noteClient = dependencies.noteClient
        let records = try await noteClient.search(cleanQuery, 5)
        try requireUnchangedProfile(profile)

        let count = records.count
        guard AutomationPreferences.exposesNoteTitles else {
            return .result(
                value: [],
                dialog: count == 0
                    ? "No notes matched \(cleanQuery)."
                    : "Found up to \(count) matches. Open Ijuka to view them."
            )
        }

        let entities = records.compactMap {
            NoteEntity(context: profile, note: $0)?.systemSafeEntity()
        }
        return .result(
            value: entities,
            dialog: count == 0
                ? "No notes matched \(cleanQuery)."
                : "Found \(count) matching note\(count == 1 ? "" : "s")."
        )
    }
}

// MARK: - Sync

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Now"
    static let description = IntentDescription("Syncs the active Ijuka collection with your sync server.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Include Media", default: false)
    var includeMedia: Bool

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = AccountStore.shared.selectedContext
        if includeMedia, #available(iOS 26.0, macOS 26.0, *) {
            try await requestConfirmation(
                actionName: .continue,
                dialog: "Include media in this sync? This can take substantially longer and use more data."
            )
        }

        let dependencies = IntentDependencies()
        let coordinator = dependencies.syncCoordinator
        try requireUnchangedProfile(profile)
        let result = await coordinator.startSyncAndWait(includeMedia: includeMedia)
        try requireUnchangedProfile(profile)
        switch result {
        case .success(let summary):
            let media = includeMedia ? " Media sync finished." : ""
            return .result(
                dialog: "Sync complete. \(summary.cardsPushed) cards and \(summary.notesPushed) notes uploaded; \(summary.cardsPulled) cards and \(summary.notesPulled) notes downloaded.\(media)"
            )
        case .noServer:
            return .result(dialog: "No sync server is configured.")
        case .needsLogin:
            AppNavigationCoordinator.shared.submit(.presentSync, profile: profile)
            return .result(dialog: "Sign-in is required. Opening Ijuka Sync Settings.")
        case .needsFullSync:
            AppNavigationCoordinator.shared.submit(.presentSync, profile: profile)
            return .result(dialog: "A full-sync choice is required. Opening Ijuka.")
        case .cancelled:
            return .result(dialog: "Sync was cancelled.")
        case .failed(let message):
            return .result(dialog: "Sync failed: \(message)")
        }
    }
}

// MARK: - Open deck

struct OpenDeckIntent: AppIntent, OpenIntent {
    static let title: LocalizedStringResource = "Open Deck in Browse"
    static let description = IntentDescription("Opens the cards and notes for a deck in Browse.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Deck")
    var target: DeckEntity

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = AccountStore.shared.selectedContext
        let deck = target
        let deckID = try deck.resolvedDeckID(currentProfileID: profile.id)
        AppNavigationCoordinator.shared.submit(
            .browseDeck(deckID: deckID.rawValue),
            profile: profile
        )
        try requireUnchangedProfile(profile)
        return .result(dialog: "Opening \(deck.name) in Browse…")
    }
}

// MARK: - Errors

enum AppIntentError: LocalizedError {
    case emptyFront
    case emptySearch
    case noCompatibleNotetype
    case unsupportedNotetype(String)
    case invalidDeck
    case profileChanged

    var errorDescription: String? {
        switch self {
        case .emptyFront:
            "Enter text for the front of the card."
        case .emptySearch:
            "Enter something to search for."
        case .noCompatibleNotetype:
            "This profile has no normal note type with two writable fields. Choose a note type in the Ijuka editor."
        case .unsupportedNotetype(let name):
            "The \(name) note type does not have two writable fields for Quick Add."
        case .invalidDeck:
            "That deck is no longer available. Choose it again."
        case .profileChanged:
            "The active profile changed. Try the action again."
        }
    }
}

@MainActor
private func requireUnchangedProfile(_ expected: ProfileContext) throws {
    guard AccountStore.shared.selectedContext == expected else {
        throw AppIntentError.profileChanged
    }
}
