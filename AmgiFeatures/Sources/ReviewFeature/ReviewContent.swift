import SwiftUI
import AmgiCardWeb
import AmgiTheme
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AnkiClients
import AnkiKit
import Dependencies
import BrowseFeature
import TemplatesFeature
import Sharing
import AmgiReviewCore
import SwiftUINavigation

// MARK: - Content

/// Pure render surface for a review session: the card/finished views,
/// toolbar, and edit/lookup sheets. Takes the session read-only plus pref
/// values and sheet bindings — no lifecycle, so a `#Preview` renders it
/// with a stub session and no backend.
struct ReviewContent: View {
    let session: ReviewSession
    let showRemainingDays: Bool
    let autoMatchCardBackground: Bool
    let openLinksExternally: Bool
    let cardContentAlignment: String
    let tapLookup: Bool
    let showNextReviewTime: Bool
    @Binding var destination: ReviewDestination?
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette
    /// Supplied by the app root — see `EnvironmentValues.lookupPopup`. Keeping
    /// the popup itself out of this target is what keeps it off the Cxx chain.
    @Environment(\.lookupPopup) private var lookupPopup
    @State private var cardActions = CardContextMenuModel()
    @State private var confirmDeleteNote = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showRemainingDays && session.startError == nil {
                    progressBar
                }

                if let startError = session.startError {
                    startFailureView(startError)
                } else if session.isFinished {
                    finishedView
                } else {
                    ReviewCardArea(
                        session: session,
                        openLinksExternally: openLinksExternally,
                        cardContentAlignment: cardContentAlignment,
                        tapLookup: tapLookup,
                        showNextReviewTime: showNextReviewTime,
                        lookupQuery: lookupQuery
                    )
                }
            }
            .background(palette.background)
            // Haptics fire on the causal event, not on its consequences: the
            // rating tap itself, and the undo actually landing. `.again` gets
            // a firmer tap than the other three — it's the one answer that
            // costs the user something, and matching the feedback's character
            // to the action is the point.
            .sensoryFeedback(trigger: session.answerTapCount) { _, _ in
                session.tappedRating == .again
                    ? .impact(weight: .medium)
                    : .impact(weight: .light)
            }
            .sensoryFeedback(.success, trigger: session.undoneCount)
            .sensoryFeedback(trigger: session.isFinished) { _, finished in
                finished ? .success : nil
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .principal) {
                    Text(session.deckName)
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if showRemainingDays {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(cardPosition)/\(max(sessionTotal, 1))")
                            .amgiFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                            .accessibilityLabel("Card \(cardPosition) of \(max(sessionTotal, 1))")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!session.canUndo)
                    .accessibilityLabel("Undo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    cardActionsMenu
                }
            }
            .cardActionPresentations(
                model: cardActions,
                cardId: session.currentCardId,
                noteId: session.currentNote?.id,
                confirmDeleteNote: $confirmDeleteNote
            )
            .toolbarBackground(
                autoMatchCardBackground ? session.cardChromeColor : Color.clear,
                for: .navigationBar
            )
            .toolbarBackground(
                autoMatchCardBackground ? .visible : .automatic,
                for: .navigationBar
            )
            .toolbarColorScheme(
                autoMatchCardBackground && session.cardChromeIsDark ? .dark : .light,
                for: .navigationBar
            )
            .sheet(item: $destination.editNote) { note in
                NavigationStack {
                    NoteEditorView(note: note) {
                        Task { await session.refreshAfterEdit() }
                    }
                }
            }
            .sheet(item: $destination.editTemplate) { target in
                NavigationStack {
                    TemplateEditorView(
                        notetypeId: target.notetypeId,
                        initialTemplateIndex: target.ordinal,
                        mode: .currentCard,
                        onSaved: { await session.refreshAfterEdit() }
                    )
                }
            }
            .sheet(isPresented: Binding($destination.lookup)) {
                if let lookupPopup {
                    lookupPopup.popup(query: lookupQuery.wrappedValue ?? "") {
                        destination = nil
                    }
                }
            }
        }
    }

    /// `ReviewCardArea` drives lookup from a tap on the card and knows nothing
    /// about the destination enum, so it keeps a plain `String?`. Hand-rolled
    /// rather than `$destination.lookup`, because a case-path binding refuses
    /// writes while a *different* case is active — including the nil→lookup
    /// write that opens the popup in the first place.
    private var lookupQuery: Binding<String?> {
        Binding(
            get: { if case .lookup(let text) = destination { return text }; return nil },
            set: { destination = $0.map(ReviewDestination.lookup) }
        )
    }

    // MARK: - Progress

    /// Total cards in this session = already reviewed + still queued. The
    /// queued total shifts as learning cards re-enter the queue, so this
    /// tracks the session rather than a fixed count.
    private var sessionTotal: Int {
        session.sessionStats.reviewed + session.remainingCounts.total
    }

    /// 1-indexed position of the current card, clamped so it never exceeds
    /// the (moving) total.
    private var cardPosition: Int {
        min(session.sessionStats.reviewed + 1, max(sessionTotal, 1))
    }

    private var progressFraction: Double {
        sessionTotal > 0 ? Double(session.sessionStats.reviewed) / Double(sessionTotal) : 0
    }

    /// Thin session-progress bar under the navigation bar (replaces the old
    /// counts row). The numeric position lives in the toolbar.
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.separator)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(0, geo.size.width * progressFraction))
            }
        }
        .frame(height: 3)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .animation(AmgiMotion.standard, value: progressFraction)
    }

    // MARK: - Card actions

    /// Every card action in one flat menu: the flag palette, this screen's own
    /// edit/lookup/audio items, then the shared card and note sections. No
    /// submenus and no duplicated Undo — Undo is a toolbar button of its own,
    /// since it's the action a reviewer reaches for mid-session.
    ///
    /// The label keeps its `…` shape whatever the flag state; a flagged card
    /// only tints it, so the "more actions" affordance never changes glyph
    /// under the user.
    @ViewBuilder
    private var cardActionsMenu: some View {
        Menu {
            if let cardId = session.currentCardId {
                CardFlagPicker(model: cardActions, cardId: cardId)
            }

            Section {
                Button {
                    destination = session.currentNote.map(ReviewDestination.editNote)
                } label: {
                    Label("Edit Note", systemImage: "pencil")
                }
                .disabled(session.currentNote == nil)

                Button {
                    destination = session.currentTemplateTarget.map(ReviewDestination.editTemplate)
                } label: {
                    Label("Edit Template", systemImage: "square.and.pencil")
                }
                .disabled(session.currentTemplateTarget == nil)

                Button {
                    // Empty initial query opens the popup focused for typing.
                    // Future enhancement: forward CardWebView text-selection so
                    // the query is pre-populated.
                    destination = .lookup("")
                } label: {
                    Label("Look Up", systemImage: "character.book.closed")
                }

                Button {
                    if session.isAudioPlaying {
                        session.bumpStopAudioRequest()
                    } else {
                        session.bumpReplayRequest()
                    }
                } label: {
                    Label(
                        session.isAudioPlaying ? "Stop Audio" : "Replay Audio",
                        systemImage: session.isAudioPlaying ? "pause.circle" : "play.circle"
                    )
                }
                .disabled(session.currentNote == nil)
            }

            if let cardId = session.currentCardId {
                CardActionSections(
                    model: cardActions,
                    cardId: cardId,
                    noteId: session.currentNote?.id,
                    confirmDeleteNote: $confirmDeleteNote
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(
                    cardActions.currentFlag == 0
                        ? palette.accent
                        : CardFlag.color(cardActions.currentFlag)
                )
        }
        .accessibilityLabel("Card actions")
    }

    /// Distinct from `finishedView`. A failed `start()` used to land on the
    /// congratulations surface — green checkmark, "You've reviewed 0 cards",
    /// success haptic — which reported a backend failure as a completed deck.
    private func startFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Start Reviewing", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { session.start() }
                .buttonStyle(AmgiPrimaryButtonStyle())
        }
    }

    private var finishedView: some View {
        VStack(spacing: AmgiSpacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(palette.positive)
                .accessibilityHidden(true)   // "Congratulations!" below says it
            Text("Congratulations!")
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            Text("You've reviewed \(session.sessionStats.reviewed) cards")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
            if session.sessionStats.reviewed > 0 {
                Text("Accuracy: \(Int(session.sessionStats.accuracy * 100))%")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button("Done") { onDismiss() }
                .buttonStyle(AmgiPrimaryButtonStyle())
                .padding()
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Question") {
    ReviewContent(
        session: .preview(showAnswer: false),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        onDismiss: {}
    )
}

#Preview("Answer") {
    ReviewContent(
        session: .preview(showAnswer: true),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        onDismiss: {}
    )
}

#Preview("Finished") {
    ReviewContent(
        session: .preview(isFinished: true),
        showRemainingDays: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        destination: .constant(nil),
        onDismiss: {}
    )
}
#endif
