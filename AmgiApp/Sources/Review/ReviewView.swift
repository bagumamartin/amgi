import SwiftUI
import AmgiCardWeb
import AmgiTheme
import AmgiUI
import AnkiBackend
import AnkiKit
import Dependencies
import Sharing

/// Container: owns the `ReviewSession`, the review preferences, the sheet
/// selection state, and the session lifecycle (`start()`, audio-session
/// application, widget snapshot on disappear). Hands the session plus pref
/// values and sheet bindings to the pure `ReviewContent`, which is what the
/// `#Preview`s build with a stub session.
struct ReviewView: View {
    let deckId: DeckID
    let onDismiss: () -> Void

    @Shared(.appStorage(ReviewPreferences.Keys.showAudioReplayButton))
    private var showAudioReplayButton: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showContextMenuButton))
    private var showContextMenuButton: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.openLinksExternally))
    private var openLinksExternally: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.cardContentAlignment))
    private var cardContentAlignment: String = CardWebViewContentAlignment.center.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.autoMatchCardBackground))
    private var autoMatchCardBackground: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showRemainingDays))
    private var showRemainingDays: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showNextReviewTime))
    private var showNextReviewTime: Bool = true

    @Shared(.appStorage(ReaderPreferences.Keys.tapLookup))
    private var tapLookup: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.playAudioInSilentMode))
    private var playAudioInSilentMode: Bool = false

    @State private var session: ReviewSession
    @State private var editingNote: NoteRecord?
    @State private var editingTemplate: ReviewSession.TemplateTarget?
    @State private var lookupQuery: String?

    init(deckId: DeckID, onDismiss: @escaping () -> Void) {
        self.deckId = deckId
        self.onDismiss = onDismiss
        self._session = State(initialValue: ReviewSession(deckId: deckId))
    }

    var body: some View {
        ReviewContent(
            session: session,
            showRemainingDays: showRemainingDays,
            showAudioReplayButton: showAudioReplayButton,
            showContextMenuButton: showContextMenuButton,
            autoMatchCardBackground: autoMatchCardBackground,
            openLinksExternally: openLinksExternally,
            cardContentAlignment: cardContentAlignment,
            tapLookup: tapLookup,
            showNextReviewTime: showNextReviewTime,
            editingNote: $editingNote,
            editingTemplate: $editingTemplate,
            lookupQuery: $lookupQuery,
            onDismiss: onDismiss
        )
        .task {
            ReviewAudioSession.apply(playInSilent: playAudioInSilentMode)
            session.start()
        }
        .onChange(of: playAudioInSilentMode) { _, newValue in
            ReviewAudioSession.apply(playInSilent: newValue)
        }
        .onDisappear {
            #if os(macOS)
            // The review lives in its own window; on close there's no
            // parent cover to run the onDismiss bookkeeping, so broadcast
            // for the main window's ContentView to invalidate the store.
            NotificationCenter.default.post(name: .amgiReviewFinished, object: nil)
            #endif
            Task { await writeWidgetSnapshot() }
        }
    }
}

// MARK: - Content

/// Pure render surface for a review session: the card/finished views,
/// toolbar, and edit/lookup sheets. Takes the session read-only plus pref
/// values and sheet bindings — no lifecycle, so a `#Preview` renders it
/// with a stub session and no backend.
private struct ReviewContent: View {
    let session: ReviewSession
    let showRemainingDays: Bool
    let showAudioReplayButton: Bool
    let showContextMenuButton: Bool
    let autoMatchCardBackground: Bool
    let openLinksExternally: Bool
    let cardContentAlignment: String
    let tapLookup: Bool
    let showNextReviewTime: Bool
    @Binding var editingNote: NoteRecord?
    @Binding var editingTemplate: ReviewSession.TemplateTarget?
    @Binding var lookupQuery: String?
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var showRenderModeSheet = false
    @State private var showUndoToast = false
    @Environment(\.dismiss) private var dismiss
    @Shared(.reviewShortcuts) private var reviewShortcuts: [String: ReviewShortcut] = [:]
    // Stable-identity focused value — see `ReviewActions`. Created once per
    // screen; closures rebound in `onAppear` (all captures are stable
    // references, so rebinding once is sufficient).
    @State private var reviewActions = ReviewActions()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showRemainingDays {
                    DailyProgressBar(
                        completedToday: session.dailyCompletedToday,
                        remainingToday: session.dailyRemainingToday,
                        remainingCounts: session.remainingCounts
                    ) {
                        ReviewContextDots(session: session)
                    }
                }

                if session.isFinished {
                    finishedView
                } else {
                    ReviewCardArea(
                        session: session,
                        openLinksExternally: openLinksExternally,
                        cardContentAlignment: cardContentAlignment,
                        tapLookup: tapLookup,
                        showNextReviewTime: showNextReviewTime,
                        lookupQuery: $lookupQuery
                    )
                }
            }
            // The review chrome (progress strip, card well, answer-button
            // region) should sit on the same background as the navigation
            // bar above it. When auto-matching is on that's the card's own
            // chrome colour (light/dark aware per card); otherwise fall back
            // to the theme palette, which is itself resolved for the active
            // colour scheme.
            .background(autoMatchCardBackground ? session.cardChromeColor : palette.background)
            .environment(\.palette, contentPalette)
            // A graduation (not just any answer) triggers a long continuous
            // haptic — the Duolingo-style "got it right" feel.
            .onChange(of: session.graduationPulse) { _, _ in
                #if os(iOS)
                GraduationHaptics.play()
                #endif
            }
            .onChange(of: session.undoToastPulse) { _, _ in
                showUndoToast = true
            }
            .task(id: session.undoToastPulse) {
                guard session.undoToastPulse > 0 else { return }
                try? await Task.sleep(for: .seconds(1.2))
                showUndoToast = false
            }
            .overlay {
                if showUndoToast {
                    undoToast
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            #if os(iOS)
            // Register the review shortcuts for hardware keyboards (iPad Magic
            // Keyboard / iPhone Bluetooth keyboard). The on-screen actions live
            // in the overflow Menu, whose buttons only materialize once the menu
            // opens — so they never register their `.keyboardShortcut` equivalents.
            // These zero-size buttons mirror the persisted bindings instead.
            .overlay {
                reviewKeyboardShortcuts
                    .frame(width: 0, height: 0)
                    .clipped()
                    .accessibilityHidden(true)
            }
            #endif
            #if os(macOS)
            // The macOS menu bar targets whichever review window is focused.
            // Do not install this closure-backed focused value on iPadOS: the
            // scene observes it to rebuild commands while this view recreates
            // it during rendering, which can cause a same-frame update loop
            // and leave the review hierarchy temporarily unresponsive.
            //
            // `reviewActions` is a stable class instance (see `ReviewActions`);
            // writing the same reference every render is a no-op for SwiftUI's
            // change detection, which is what breaks the update loop.
            .focusedSceneValue(\.reviewActions, reviewActions)
            .onAppear {
                reviewActions.undo = { session.undo() }
                reviewActions.editNote = { editingNote = session.currentNote }
                reviewActions.lookup = { lookupQuery = "" }
                reviewActions.replayAudio = {
                    if session.isAudioPlaying {
                        session.bumpStopAudioRequest()
                    } else {
                        session.bumpReplayRequest()
                    }
                }
            }
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if !os(macOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                #endif
                #if os(iOS)
                // Title sits immediately right of the dismiss button, but as
                // its OWN toolbar item with the shared glass background
                // removed — grouping it with the X fuses both into one pill
                // that's too small for the deck/subdeck combination and
                // ellipsizes the title. Plain text keeps the X's circular
                // glass intact.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        reviewTitleBlock
                            // Breathing room from the X button's glass circle.
                            .padding(.leading, 16)
                            // Toolbar items propose a narrow width that
                            // scales+ellipsizes the title; take the text's
                            // ideal width instead (lineLimit(1) still caps
                            // pathologically long names at the screen edge).
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        reviewTitleBlock
                            .padding(.leading, 32)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                #endif
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EngineUndoButton()
                    SyncToolbarButton()
                    cardActionsMenu
                }
            }
            #if os(macOS)
            // macOS HIG: the deck name is the window title (no inline title
            // bar) — left-leaning, plain, no principal-item glass pill.
            // "Parent::Child" renders as a "Parent › Child" breadcrumb so
            // the hierarchy reads without the engine's separator clutter.
            .navigationTitle(navigationBreadcrumb)
            .onExitCommand {
                if !session.requiresTypedAnswerInput {
                    dismiss()
                }
            }
            #endif
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
            .sheet(isPresented: $showRenderModeSheet) {
                RenderModeSheet(
                    explainer: renderModeExplainer,
                    template: session.currentTemplateTarget,
                    templateName: session.templateName,
                    onChanged: { session.reresolveCurrentCard() }
                )
            }
            .sheet(item: $editingNote) { note in
                NavigationStack {
                    NoteEditorView(note: note) {
                        Task { await session.refreshAfterEdit() }
                    }
                }
            }
            .sheet(item: $editingTemplate) { target in
                NavigationStack {
                    TemplateEditorView(
                        notetypeId: target.notetypeId,
                        initialTemplateIndex: target.ordinal,
                        mode: .currentCard,
                        onSaved: { await session.refreshAfterEdit() }
                    )
                }
            }
            .sheet(item: Binding(
                get: { lookupQuery.map(ReviewLookupQuery.init) },
                set: { lookupQuery = $0?.text }
            )) { wrapped in
                LookupPopupView(initialQuery: wrapped.text) {
                    lookupQuery = nil
                }
            }
        }
    }

    // MARK: - Progress

    /// Brief centered confirmation shown for ~1.2s after an undo.
    private var undoToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
            Text("Undo")
                .amgiFont(.bodyEmphasis)
        }
        .foregroundStyle(palette.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.surfaceElevated, in: Capsule())
        .overlay {
            Capsule().strokeBorder(palette.textSecondary.opacity(0.4), lineWidth: 1)
        }
    }

    /// The review title block for the leading toolbar area: the deck name
    /// (parent) in the large font, the subdeck leaf below it in the small
    /// one. Top-level decks (no parent) render the leaf alone at full size.
    private var reviewTitleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !deckSubtitle.isEmpty {
                Text(deckSubtitle)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(deckTitle)
                .amgiFont(deckSubtitle.isEmpty ? .bodyEmphasis : .micro)
                .foregroundStyle(deckSubtitle.isEmpty ? palette.textPrimary : palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Leaf deck name, with the parent path stripped. The backend hands    /// back a "Parent::Child" path; the leaf alone is what a reviewer
    /// actually needs to identify which deck they're studying.
    private var deckTitle: String {
        session.deckName.components(separatedBy: "::").last?.trimmingCharacters(in: .whitespaces) ?? session.deckName
    }

    /// The parent path of the current deck, shown as a small subtitle above
    /// the title so context isn't lost. Empty for top-level decks.
    private var deckSubtitle: String {
        let parts = session.deckName.components(separatedBy: "::")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: " - ")
    }

    /// "Parent::Child" rendered as a "Parent › Child" breadcrumb for the
    /// window title — the engine's `::` separator reads as clutter; a
    /// chevron keeps the hierarchy legible without it.
    private var navigationBreadcrumb: String {
        session.deckName
            .components(separatedBy: "::")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " › ")
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

    // MARK: - Card actions

    /// The single overflow menu that replaces the row of toolbar icons:
    /// undo, edit note, look up, replay audio, and card/template options.
    /// Individual items carry their own disabled state so undo stays
    /// reachable even when there's no current note (e.g. finished screen).
    @ViewBuilder
    private var cardActionsMenu: some View {
        Menu {
            Button {
                session.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo)

            Button {
                editingNote = session.currentNote
            } label: {
                Label("Edit Note", systemImage: "pencil")
            }
            .disabled(session.currentNote == nil)

            Button {
                // Empty initial query opens the popup focused for typing.
                // Future enhancement: forward CardWebView text-selection so
                // the query is pre-populated.
                lookupQuery = ""
            } label: {
                Label("Look Up", systemImage: "character.book.closed")
            }

            if showAudioReplayButton {
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

            Divider()
            Button {
                showRenderModeSheet = true
            } label: {
                Label("Card Rendering", systemImage: "paintbrush")
            }

            if showContextMenuButton {
                if let cardId = session.currentCardId {
                    CardContextMenu(cardId: cardId, noteId: session.currentNote?.id, includeUndo: false)
                }
                Button {
                    editingTemplate = session.currentTemplateTarget
                } label: {
                    Label("Edit Template", systemImage: "square.and.pencil")
                }
                .disabled(session.currentTemplateTarget == nil)
            }
        } label: {
            if session.currentFlag != 0 {
                Image(systemName: "flag.fill")
                    .foregroundStyle(flagColor(for: session.currentFlag))
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .accessibilityLabel("Card options")
        #if os(macOS)
        .help("Card options")
        #endif
    }

    // MARK: - Keyboard shortcuts (iOS)

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

            Button("Edit Note") { editingNote = session.currentNote }
                .keyboardShortcut(shortcut(.editNote).keyEquivalent, modifiers: shortcut(.editNote).modifiers)
                .disabled(session.currentNote == nil)

            Button("Look Up") { lookupQuery = "" }
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
        }
    }

    private func shortcut(_ action: ReviewShortcutAction) -> ReviewShortcut {
        reviewShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    private var renderModeExplainer: String {
        switch session.resolvedMode {
        case .native:
            return "rendered natively — passes the simplicity check."
        case .html:
            let prefs = currentRenderEnginePreferences(
                mid: session.currentNote?.mid,
                ord: Int(session.currentCardOrdinal)
            )
            if (prefs.override ?? prefs.global) == .alwaysHTML {
                return "rendered as HTML — selected for this card."
            }
            return "rendered as HTML — uses features the native renderer doesn't support."
        }
    }

    private var finishedView: some View {
        VStack(spacing: AmgiSpacing.lg) {
            #if os(macOS)
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(palette.positive)
            Text("Congratulations!")
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            Text("You've reviewed \(session.sessionStats.reviewed) cards")
                .foregroundStyle(palette.textSecondary)
            if session.sessionStats.reviewed > 0 {
                Text("Accuracy: \(Int(session.sessionStats.accuracy * 100))%")
                    .foregroundStyle(palette.textSecondary)
            }
            if session.dailyRemainingToday > 0 {
                Text("\(session.dailyRemainingToday) due later today")
                    .foregroundStyle(palette.textSecondary)
                    .font(.callout)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding()
            #else
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(palette.positive)
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
            #endif
        }
    }
}

private extension ReviewContent {
    func flagColor(for value: UInt32) -> Color {
        switch value & 0b111 {
        case 1: return .red
        case 2: return .orange
        case 3: return .green
        case 4: return .blue
        case 5: return .pink
        case 6: return .cyan
        case 7: return .purple
        default: return .secondary
        }
    }
}

// MARK: - Card Area

/// Title-bar context dots for the reviewer: the current card's scheduling/// category and its last rating, color-coded with the same hues as the
/// progress indicators and rating bar. Dots only — color carries the
/// meaning; a hairline ring keeps them visible on tinted card chrome.
/// The rating dot is tappable to repeat the last rating (new cards default
/// to Again); it dims while the answer isn't showing, since repeat only
/// applies then.
private struct ReviewContextDots: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            contextDot(stateColor)
                .accessibilityLabel(stateLabel)
            ratingDot
        }
    }

    private var stateColor: Color {
        switch session.currentCardState {
        case .new: palette.cardStateNew
        case .learning: palette.cardStateLearning
        case .review: palette.cardStateReview
        case .relearning: palette.cardStateLearning // relearning is learning for the progress bar (orange, not red)
        }
    }

    private var stateLabel: String {
        switch session.currentCardState {
        case .new: "New card"
        case .learning, .relearning: "Learning"
        case .review: "Review"
        }
    }

    /// Same hue mapping the rating bar uses (Again/Good ↔ relearn/review
    /// etc.). Never-reviewed cards show the new-state hue.
    private var lastRatingColor: Color {
        switch session.currentCardLastRating {
        case .again: palette.cardStateRelearn
        case .hard: palette.cardStateLearning
        case .good: palette.cardStateReview
        case .easy: palette.cardStateNew
        case nil: palette.cardStateNew
        }
    }

    /// Neutral grey used *before* the answer is revealed so the dot doesn't
    /// give away the previous rating's hue. Theme-aware via the palette
    /// (`cardStateSuspended` is the designated neutral state grey and exists
    /// in every palette / light+dark variant, unlike a hardcoded `Color.gray`).
    private var neutralRatingColor: Color {
        palette.cardStateSuspended
    }

    /// The color actually painted for the rating dot — neutral grey on the
    /// front, the true rating hue only after `showAnswer`.
    private var effectiveRatingColor: Color {
        session.showAnswer ? lastRatingColor : neutralRatingColor
    }

    private var lastRatingLabel: String {
        switch session.currentCardLastRating {
        case .again: "Last rated Again"
        case .hard: "Last rated Hard"
        case .good: "Last rated Good"
        case .easy: "Last rated Easy"
        case nil: "Never reviewed"
        }
    }

    private func contextDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(palette.separator.opacity(0.5), lineWidth: 1))
    }

    private var ratingDot: some View {
        Button {
            session.answerWithLastRating()
        } label: {
            contextDot(effectiveRatingColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.showAnswer || session.isAdvancing)
        .opacity(session.isAdvancing ? 0.45 : 1)
        .accessibilityLabel("\(lastRatingLabel). Tap to repeat it")
    }
}

/// The card region of the reviewer: flip surface plus reveal/rating controls./// Extracted from `ReviewContent` so session mutations it doesn't read
/// (audio-playing toggles, toast, deck counts) skip its body — otherwise every
/// such change re-runs `CardWebView.updateUIView` and its HTML processing.
/// Owns the native audio player, which is only relevant here.
private struct ReviewCardArea: View {
    let session: ReviewSession
    let openLinksExternally: Bool
    let cardContentAlignment: String
    let tapLookup: Bool
    let showNextReviewTime: Bool
    @Binding var lookupQuery: String?

    @Environment(\.palette) private var palette
    @State private var nativeAudioPlayer = NativeCardAudioPlayer()
    @Shared(.reviewShortcuts) private var reviewShortcuts: [String: ReviewShortcut] = [:]

    private func shortcut(_ action: ReviewShortcutAction) -> ReviewShortcut {
        reviewShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    var body: some View {
        VStack(spacing: 0) {
            cardFlipRegion
            .onChange(of: session.stopAudioRequestID) { _, _ in
                if isNativeMode { nativeAudioPlayer.stop() }
            }
            .onChange(of: session.currentCardId) { _, _ in playNativeAudio() }
            .onChange(of: session.showAnswer) { _, shown in
                if shown { playNativeAudio() }
            }
            .onChange(of: session.replayRequestID) { _, _ in playNativeAudio() }
            .onChange(of: nativeAudioPlayer.isPlaying) { _, playing in
                if isNativeMode { session.updateAudioPlaying(playing) }
            }
            .onDisappear { nativeAudioPlayer.stop() }

            Spacer()

            if session.requiresTypedAnswerInput {
                TypedAnswerField(session: session)
            }

            if session.showAnswer {
                answerButtons
                // Space repeats the card's PREVIOUS rating (Again for new
                // cards) — the answer-side counterpart of the reveal
                // shortcut below. Hidden zero-size button, same pattern as
                // the iOS review keyboard shortcuts. Not installed while a
                // typed-answer field is up: space must keep typing spaces.
                if !session.requiresTypedAnswerInput {
                    Button {
                        session.answerWithLastRating()
                    } label: {
                        Text("Repeat Last Rating")
                    }
                    .keyboardShortcut(
                        shortcut(.repeatLastRating).keyEquivalent,
                        modifiers: shortcut(.repeatLastRating).modifiers
                    )
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .disabled(session.isAdvancing)
                }
            } else if session.requiresTypedAnswerInput {
                // No reveal shortcut while the typed-answer field is active —
                // it would steal spaces from the user's input.
                revealButton
            } else {
                revealButton
                    .keyboardShortcut(
                        shortcut(.revealAnswer).keyEquivalent,
                        modifiers: shortcut(.revealAnswer).modifiers
                    )
            }
        }
        #if os(macOS)
        // macOS HIG: bound the review column to a comfortable reading width
        // and center it, so full-screen/wide windows don't stretch the card,
        // chip row, and buttons edge to edge (left-anchored).
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        #endif
    }

    private var revealButton: some View {
        Button {
            session.revealAnswer()
        } label: {
            #if os(macOS)
            // macOS HIG: standard-sized prominent button — not the iOS
            // full-width slab. Space (and Return in the typed-answer field)
            // already reveal from the keyboard.
            Text("Show Answer")
            #else
            Text("Show Answer")
                .amgiFont(.bodyEmphasis)
                .frame(maxWidth: .infinity)
                .padding()
            #endif
        }
        .buttonStyle(.borderedProminent)
        // A single consistent accent blue for every deck — the per-deck
        // hashed tone was meant for deck tiles, not the primary action,
        // and made "Show Answer" shift colour as you moved between decks.
        .tint(palette.accent)
        #if os(macOS)
        .controlSize(.large)
        .help("Show Answer (\(shortcut(.revealAnswer).displayString))")
        #else
        // A full-width primary action is ergonomic on an iPhone, but becomes
        // an impersonal, hard-to-scan slab on iPad. Cap its readable/tappable
        // width while keeping it centered; compact widths remain naturally
        // full-width because their available space is below the cap.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        #endif
        .disabled(session.isAdvancing)
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.vertical, AmgiSpacing.md)
    }

    private var isNativeMode: Bool {
        if case .native = session.resolvedMode { return true }
        return false
    }

    /// The reveal region. Native cards get the 3D flip (pure SwiftUI, crisp);
    /// WebView cards swap sides without rotation, because 3D-rotating a live
    /// `WKWebView` rasterizes to a blurred frame mid-flip.
    @ViewBuilder
    private var cardFlipRegion: some View {
        if isNativeMode {
            FlipContainer(showBack: session.showAnswer) { isBack in
                cardSurface(isBack: isBack)
            }
        } else {
            cardSurface(isBack: session.showAnswer)
        }
    }


    private var mediaFolder: URL? {
        @Dependency(\.ankiBackend) var backend
        guard let path = backend.currentMediaFolderPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    @ViewBuilder
    private func cardSurface(isBack: Bool) -> some View {
        switch session.resolvedMode {
        case .native(let front, let back):
            let resolvedBack = isBack ? back.resolvingBackAnswerSplit(front: front) : nil
            NativeCardView(
                content: resolvedBack?.content ?? front,
                isAnswerSide: isBack,
                answerStartIndex: resolvedBack?.answerStart,
                mediaFolder: mediaFolder,
                onQuestionCanvasTap: questionCanvasReveal,
                onTextLookup: textLookupCallback
            )
            // Skip body evaluation when unrelated session fields invalidate
            // `ReviewCardArea` — previously every such pass re-read media
            // images from disk mid-flip.
            .equatable()
        case .html:
            CardWebView(
                html: isBack ? session.backHTML : session.frontHTML,
                cardCSS: session.cardCSS,
                isAnswerSide: isBack,
                cardOrdinal: session.currentCardOrdinal,
                replayRequestID: session.replayRequestID,
                stopAudioRequestID: session.stopAudioRequestID,
                openLinksExternally: openLinksExternally,
                lookupPopupEnabled: tapLookup && !session.requiresTypedAnswerInput,
                contentAlignment: CardWebViewContentAlignment(rawValue: cardContentAlignment) ?? .center,
                onAudioStateChange: { playing in session.updateAudioPlaying(playing) },
                onCardBackgroundColorChange: { color, isDark in
                    session.updateCardChrome(color: color, isDark: isDark)
                },
                // No tap-lookup while the typed-answer input is up — the
                // dictionary would hand over the answer to be typed.
                onLookupRequested: tapLookup && !session.requiresTypedAnswerInput ? { text, _, _ in
                    if let text, !text.isEmpty { lookupQuery = text }
                } : nil,
                onQuestionCanvasTap: questionCanvasReveal
            )
        }
    }

    private var questionCanvasReveal: (() -> Void)? {
        #if os(iOS)
        guard !session.showAnswer,
              !session.isAdvancing,
              !session.requiresTypedAnswerInput
        else { return nil }
        return { session.revealAnswer() }
        #else
        return nil
        #endif
    }


    private func playNativeAudio() {
        guard case .native(let front, let back) = session.resolvedMode else { return }
        let files = session.showAnswer ? back.audioFiles : front.audioFiles
        guard !files.isEmpty else { return }
        let startedAt = Date()
        nativeAudioPlayer.play(files: files, mediaFolder: mediaFolder)
        print("[ReviewCardArea] playNativeAudio took \(Int(Date().timeIntervalSince(startedAt) * 1000))ms for \(files.count) file(s)")
    }

    private var answerButtons: some View {
        RatingBar(
            intervals: session.nextIntervals,
            showIntervals: showNextReviewTime,
            isDisabled: session.isAdvancing,
            onRate: { rating in session.answer(rating: rating) }
        )
    }

    private var textLookupCallback: ((String) -> Void)? {
        guard tapLookup, !session.requiresTypedAnswerInput else { return nil }
        return { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lookupQuery = trimmed }
        }
    }
}

/// Native input for typed-answer (`{{type:}}`) cards. Native rather than an
/// in-card HTML input because WKWebView ignores web keyboard attributes and
/// the predictive bar would offer the answer as a suggestion.
private struct TypedAnswerField: View {
    @Bindable var session: ReviewSession
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Type the answer", text: $session.typedAnswer)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .onSubmit { session.revealAnswer() }
            .focused($focused)
            .padding(.horizontal)
            .onAppear { focused = true }
    }
}

/// Identifiable wrapper so `.sheet(item:)` can distinguish "not
/// presented" from "presented with empty query" — the toolbar button
/// opens the lookup popup focused on the search bar with no query yet.
/// The id is the query text: a fresh `UUID()` here would change identity
/// on every body re-evaluation, making SwiftUI endlessly dismiss and
/// re-present the sheet (the "stuck lookup loop" bug).
private struct ReviewLookupQuery: Identifiable {
    var id: String { text }
    let text: String
}

// MARK: - Previews

#if DEBUG
#Preview("Question") {
    ReviewContent(
        session: .preview(showAnswer: false),
        showRemainingDays: true,
        showAudioReplayButton: true,
        showContextMenuButton: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        editingNote: .constant(nil),
        editingTemplate: .constant(nil),
        lookupQuery: .constant(nil),
        onDismiss: {}
    )
}

#Preview("Answer") {
    ReviewContent(
        session: .preview(showAnswer: true),
        showRemainingDays: true,
        showAudioReplayButton: true,
        showContextMenuButton: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        editingNote: .constant(nil),
        editingTemplate: .constant(nil),
        lookupQuery: .constant(nil),
        onDismiss: {}
    )
}

#Preview("Finished") {
    ReviewContent(
        session: .preview(isFinished: true),
        showRemainingDays: true,
        showAudioReplayButton: true,
        showContextMenuButton: true,
        autoMatchCardBackground: false,
        openLinksExternally: true,
        cardContentAlignment: CardWebViewContentAlignment.center.rawValue,
        tapLookup: true,
        showNextReviewTime: true,
        editingNote: .constant(nil),
        editingTemplate: .constant(nil),
        lookupQuery: .constant(nil),
        onDismiss: {}
    )
}
#endif
