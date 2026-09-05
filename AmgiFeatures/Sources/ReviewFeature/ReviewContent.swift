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
    @Environment(\.colorScheme) private var colorScheme
    /// Supplied by the app root — see `EnvironmentValues.lookupPopup`. Keeping
    /// the popup itself out of this target is what keeps it off the Cxx chain.
    @Environment(\.lookupPopup) private var lookupPopup
    @Shared(.reviewShortcuts) private var reviewShortcuts: [String: ReviewShortcut] = [:]
    // Stable-identity focused value — see `ReviewActions`. Created once per
    // screen; closures rebound in `onAppear` (all captures are stable
    // references, so rebinding once is sufficient).
    @State private var reviewActions = ReviewActions()
    @State private var cardActions = CardContextMenuModel()
    @State private var confirmDeleteNote = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showRemainingDays && session.startError == nil {
                    DailyProgressBar(
                        completedToday: session.dailyCompletedToday,
                        remainingToday: session.dailyRemainingToday,
                        remainingCounts: session.remainingCounts
                    ) {
                        ReviewContextDots(session: session)
                    }
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
            // The review chrome (progress strip, card well, answer-button
            // region) sits on the same background as the navigation bar
            // above it. When auto-matching that's the card's own chrome
            // colour; otherwise the theme palette.
            .background(autoMatchCardBackground ? session.cardChromeColor : palette.background)
            .environment(\.palette, contentPalette)
            .modifier(ReviewHardwareKeyModifier(
                session: session,
                reviewShortcuts: reviewShortcuts,
                perform: performReviewShortcut
            ))
            #if os(iOS)
            .overlay { iOSShortcutOverlay }
            #endif
            #if os(macOS)
            // Stable reference: writing the same instance every render is a
            // no-op for change detection (see `ReviewActions`). Allocated
            // inline here would loop the scene at hundreds of body evals/sec.
            .focusedSceneValue(reviewActions)
            #endif
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
            .onChange(of: session.graduationPulse) { _, _ in
                // Graduation-only haptic (Duolingo-style sustained tap for a
                // card pushed past today). Kept separate from the answer-tap
                // feedback above so only graduating answers trigger it.
                #if os(iOS)
                GraduationHaptics.play()
                #endif
            }
            .onAppear {
                #if os(macOS)
                reviewActions.undo = { session.undo() }
                reviewActions.editNote = {
                    destination = session.currentNote.map(ReviewDestination.editNote)
                }
                reviewActions.lookup = { destination = .lookup("") }
                reviewActions.replayAudio = {
                    if session.isAudioPlaying {
                        session.bumpStopAudioRequest()
                    } else {
                        session.bumpReplayRequest()
                    }
                }
                #endif
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
            #if os(iOS)
            .toolbarBackground(
                autoMatchCardBackground ? session.cardChromeColor : Color.clear,
                for: .navigationBar
            )
            .toolbarBackground(
                autoMatchCardBackground ? .visible : .automatic,
                for: .navigationBar
            )
            .toolbarColorScheme(
                autoMatchCardBackground && cardChromeIsResolved
                    ? (session.cardChromeIsDark ? .dark : .light)
                    : colorScheme,
                for: .navigationBar
            )
            #endif
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

    /// The card renderer has reported a real chrome background. WebKit cards
    /// report via JS; native cards don't, so this stays `false` for them and
    /// the chrome falls back to the system appearance.
    private var cardChromeIsResolved: Bool {
        session.cardChromeColor != .clear
    }

    /// Palette for the review content. When auto-matching the card's
    /// background, the chrome must resolve light/dark against the *card*
    /// (not the system appearance) — otherwise dark-mode text lands on a
    /// light card, or vice-versa, and becomes unreadable. This mirrors the
    /// toolbar's `toolbarColorScheme` behaviour for the body below it.
    private var contentPalette: Palette {
        guard autoMatchCardBackground, cardChromeIsResolved else { return palette }
        return ThemeManager.shared.palette(forExplicitScheme: session.cardChromeIsDark ? .dark : .light)
    }

    // MARK: - Keyboard shortcuts (iOS)

    #if os(iOS)
    /// Zero-size overlay so Magic Keyboard shortcuts register even while
    /// the overflow Menu's buttons are unmounted.
    private var iOSShortcutOverlay: some View {
        reviewKeyboardShortcuts
            .frame(width: 0, height: 0)
            .clipped()
            .accessibilityHidden(true)
    }
    #endif

    /// Hidden buttons that register hardware-keyboard shortcuts on iOS/iPadOS.
    /// The on-screen actions live inside the overflow `Menu`, whose buttons are
    /// only materialized once the menu opens — so they never register their
    /// `.keyboardShortcut` equivalents. These zero-size buttons mirror the
    /// persisted bindings instead, giving Magic Keyboard / Bluetooth keyboard
    /// users the same ⌘Z / ⌘E / ⌘L / ⌘R shortcuts as macOS.
    @ViewBuilder
    private var reviewKeyboardShortcuts: some View {
        ZStack {
            Button("Undo") { session.undo() }
                .keyboardShortcut(shortcut(.undo).keyEquivalent, modifiers: shortcut(.undo).modifiers)
                .disabled(!session.canUndo)

            Button("Edit Note") {
                destination = session.currentNote.map(ReviewDestination.editNote)
            }
            .keyboardShortcut(shortcut(.editNote).keyEquivalent, modifiers: shortcut(.editNote).modifiers)
            .disabled(session.currentNote == nil)

            Button("Look Up") { destination = .lookup("") }
                .keyboardShortcut(shortcut(.lookup).keyEquivalent, modifiers: shortcut(.lookup).modifiers)

            Button("Replay Audio") {
                if session.isAudioPlaying {
                    session.bumpStopAudioRequest()
                } else {
                    session.bumpReplayRequest()
                }
            }
            .keyboardShortcut(shortcut(.replayAudio).keyEquivalent, modifiers: shortcut(.replayAudio).modifiers)
            .disabled(session.currentNote == nil)

            // Ratings live on RatingBar too, but iPad doesn't deliver
            // `.keyboardShortcut` for arrow keys to those buttons (focus
            // navigation eats them). Registering here with the mapped
            // `.upArrow` equivalents is the hardware-keyboard path.
            ForEach(Rating.allCases, id: \.self) { rating in
                let action = ReviewShortcutAction.ratingAction(for: rating)
                Button(action.title) { session.answer(rating: rating) }
                    .keyboardShortcut(shortcut(action).keyEquivalent, modifiers: shortcut(action).modifiers)
                    .disabled(!session.showAnswer || session.isAdvancing)
            }
        }
    }

    private func shortcut(_ action: ReviewShortcutAction) -> ReviewShortcut {
        reviewShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    private func performReviewShortcut(_ action: ReviewShortcutAction) {
        switch action {
        case .undo:
            session.undo()
        case .editNote:
            destination = session.currentNote.map(ReviewDestination.editNote)
        case .lookup:
            destination = .lookup("")
        case .replayAudio:
            if session.isAudioPlaying {
                session.bumpStopAudioRequest()
            } else {
                session.bumpReplayRequest()
            }
        case .revealAnswer:
            session.revealAnswer()
        case .repeatLastRating:
            guard !session.requiresTypedAnswerInput else { return }
            session.answerWithLastRating()
        case .rateAgain:
            session.answer(rating: .again)
        case .rateHard:
            session.answer(rating: .hard)
        case .rateGood:
            session.answer(rating: .good)
        case .rateEasy:
            session.answer(rating: .easy)
        }
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
            if session.dailyRemainingToday > 0 {
                Text("\(session.dailyRemainingToday) due later today")
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

/// Hardware keys land here even when a rating button isn't the first
/// responder. `.repeat` of Space/arrows is consumed so a held key can't
/// flash through the deck; ⌘Z still repeats.
private struct ReviewHardwareKeyModifier: ViewModifier {
    let session: ReviewSession
    let reviewShortcuts: [String: ReviewShortcut]
    let perform: (ReviewShortcutAction) -> Void
    @FocusState private var reviewKeysActive: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($reviewKeysActive)
            .onAppear { reviewKeysActive = true }
            .onChange(of: session.currentCardId) { _, _ in
                if !session.requiresTypedAnswerInput || session.showAnswer {
                    reviewKeysActive = true
                }
            }
            .onKeyPress { press in
                ReviewKeyDispatch.handle(
                    press,
                    bindings: reviewShortcuts,
                    isTypedAnswerEditing: session.requiresTypedAnswerInput && !session.showAnswer,
                    showAnswer: session.showAnswer,
                    perform: perform
                )
            }
    }
}
