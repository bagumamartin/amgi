import SwiftUI
import Foundation
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AmgiUI
import AnkiKit
import BrowseFeature
import ReviewFeature
import Dependencies

struct DeckDecisionRequest: Identifiable {
    let id = UUID()
    let item: DeckTriageItem
    let action: DeckTriageAction
}

enum DeckDecisionReviewMode: String, Identifiable {
    case automatic, paused
    var id: String { rawValue }
}

/// Shared by Library and its review sheet, so the same choice uses the same
/// validation, confirmation, and existing editor/session on every surface.
struct DeckDecisionPresentation: ViewModifier {
    let model: DeckListModel
    @Binding var request: DeckDecisionRequest?
    var presentsErrors = true
    let onViewDeck: (DeckInfo) -> Void
    @Dependency(\.collectionStore) private var store
    @State private var editor: Editor?
    @State private var reviewDeck: DeckInfo?
    @State private var deletion: DeckListModel.Deletion?

    private struct Editor: Identifiable {
        enum Kind { case options, addCards, suspendedCards }
        let id = UUID()
        let kind: Kind
        let deck: DeckInfo
        let item: DeckTriageItem
        let target: DeckListModel.DecisionTarget
    }

    func body(content: Content) -> some View {
        reviewPresentation(content)
            .sheet(item: $editor, onDismiss: { Task { await model.load() } }) { target in
                switch target.kind {
                case .options:
                    NavigationStack {
                        DeckConfigView(deckId: target.deck.id, deckName: target.deck.name,
                            initialCategory: .scheduling,
                            requiredActivationID: target.target.scope.activationID,
                            onSaved: {
                                store.apply(CollectionChanges(deck: true, studyQueues: true))
                                Task { await model.acknowledgeSavedSettings(target.item, target: target.target) }
                            }, onDismiss: { editor = nil })
                    }
                case .addCards:
                    AddNoteView(preselectedDeckId: target.deck.id) { editor = nil }
                case .suspendedCards:
                    BrowseView(deck: target.deck, initialFilter: "is:suspended",
                        requiredActivationID: target.target.scope.activationID,
                        onCardsRestored: {
                            Task { await model.acknowledgeChosenCards(target.item, target: target.target) }
                        })
                }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { deletion != nil || (presentsErrors && model.decisionError != nil) },
                set: { if !$0 { deletion = nil; model.decisionError = nil } }
            )) {
                if let target = deletion {
                    Button("Delete deck", role: .destructive) {
                        deletion = nil
                        Task { await model.deleteDecision(target) }
                    }
                    Button("Cancel", role: .cancel) { deletion = nil }
                } else {
                    Button("OK", role: .cancel) { model.decisionError = nil }
                }
            } message: {
                if let target = deletion {
                    Text(L10n.format("Permanently delete %lld cards and %lld subdecks?",
                        [Int64(target.deck.cardCount ?? 0), Int64(target.descendantCount)]))
                } else {
                    Text(model.decisionError ?? "")
                }
            }
            .task(id: request?.id) {
                guard let pending = request else { return }
                await handle(pending)
                if request?.id == pending.id { request = nil }
            }
    }

    private var alertTitle: String {
        if let deletion { return L10n.format("Delete “%@”?", [deletion.deck.name]) }
        return L10n.text("Couldn't complete the decision")
    }

    @ViewBuilder private func reviewPresentation(_ content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $reviewDeck, onDismiss: reviewEnded) { deck in
            ReviewView(deckId: deck.id, onDismiss: { reviewDeck = nil })
        }
        #else
        content.sheet(item: $reviewDeck, onDismiss: reviewEnded) { deck in
            ReviewView(deckId: deck.id, onDismiss: { reviewDeck = nil })
        }
        #endif
    }

    private func reviewEnded() {
        store.invalidateAll()
        Task { await model.load() }
    }

    private func handle(_ pending: DeckDecisionRequest) async {
        let item = pending.item
        switch pending.action {
        case .pause, .keepPace, .keepPaused, .deferDecision:
            await model.decide(item, action: pending.action)
        case .resume:
            let completed = await model.decide(item, action: .resume)
            if !completed, model.decisionError == nil, let target = await model.freshDecisionTarget(item) {
                editor = Editor(kind: .suspendedCards, deck: target.deck.asDeckInfo, item: item, target: target)
            }
        case .study, .pace, .addCards, .chooseCards, .delete, .viewDeck:
            guard let target = await model.freshDecisionTarget(item), !Task.isCancelled else { return }
            let deck = target.deck.asDeckInfo
            switch pending.action {
            case .study:
                if deck.counts.total > 0 { reviewDeck = deck }
                else { editor = Editor(kind: .options, deck: deck, item: item, target: target) }
            case .pace: editor = Editor(kind: .options, deck: deck, item: item, target: target)
            case .addCards: editor = Editor(kind: .addCards, deck: deck, item: item, target: target)
            case .chooseCards: editor = Editor(kind: .suspendedCards, deck: deck, item: item, target: target)
            case .delete:
                deletion = DeckListModel.Deletion(deck: target.deck, profile: target.profile, scope: target.scope)
            case .viewDeck: onViewDeck(deck)
            default: break
            }
        }
    }
}

struct DeckDecisionReviewView: View {
    let model: DeckListModel
    let mode: DeckDecisionReviewMode
    let onViewDeck: (DeckInfo) -> Void
    @State private var request: DeckDecisionRequest?
    @State private var focusedID: Int64?
    @State private var skipped: Set<Int64> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let data = model.decisionData(paused: mode == .paused, focusedID: focusedID, skipped: skipped)
        NavigationStack {
            DeckDecisionReviewContent(data: data,
                skippedCount: model.decisionData(paused: mode == .paused).items.filter { skipped.contains($0.id) }.count,
                onAction: { item, action in
                    focusedID = item.id
                    request = DeckDecisionRequest(item: item, action: action)
                }, onSkip: { item in
                    skipped.insert(item.id)
                    focusedID = nil
                }, onReviewSkipped: { skipped = []; focusedID = nil },
                onRetry: { Task { await model.load() } })
            .navigationTitle(Text(mode == .paused ? L10n.text("Review paused decks") : L10n.text("Review decisions")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .modifier(DeckDecisionPresentation(model: model, request: $request, onViewDeck: onViewDeck))
        }
    }
}
