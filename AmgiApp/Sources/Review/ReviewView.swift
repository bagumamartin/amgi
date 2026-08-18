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
    @State private var showRenderModeSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showRemainingDays {
                    SessionProgressBar(
                        initialCounts: session.sessionInitialCounts,
                        position: cardPosition,
                        total: sessionTotal,
                        remaining: session.remainingCounts.total
                    )
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
            .overlay {
                // Scope the fade to the toast subtree only. Attaching
                // `.animation(value:)` to the whole VStack also animated the
                // card swap on advance (content lands in the same transaction
                // as `pendingToast → nil`), producing a jumpy cross-fade.
                toastOverlay
                    .animation(.easeInOut(duration: 0.15), value: session.pendingToast)
            }
            #if os(macOS)
            // The macOS menu bar targets whichever review window is focused.
            // Do not install this closure-backed focused value on iPadOS: the
            // scene observes it to rebuild commands while this view recreates
            // it during rendering, which can cause a same-frame update loop
            // and leave the review hierarchy temporarily unresponsive.
            .focusedSceneValue(\.reviewActions, ReviewActions(
                undo: { session.undo() },
                editNote: { editingNote = session.currentNote },
                lookup: { lookupQuery = "" },
                replayAudio: {
                    if session.isAudioPlaying {
                        session.bumpStopAudioRequest()
                    } else {
                        session.bumpReplayRequest()
                    }
                }
            ))
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
                ToolbarItem(placement: .principal) {
                    HStack(spacing: AmgiSpacing.sm) {
                        Circle()
                            .fill(deckTone)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            if !deckSubtitle.isEmpty {
                                Text(deckSubtitle)
                                    .amgiFont(.micro)
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            Text(deckTitle)
                                .amgiFont(.bodyEmphasis)
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    cardActionsMenu
                }
            }
            #if os(macOS)
            // macOS HIG: the deck name is the window title (no inline title
            // bar) and Escape is the standard cancel/close path alongside
            // the window controls (⌘W, traffic light). Guarded so Escape
            // never closes mid-typing in a `{{type:}}` card.
            .navigationTitle(session.deckName)
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
                autoMatchCardBackground && session.cardChromeIsDark ? .dark : .light,
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

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = session.pendingToast {
            RatingToastView(toast: toast)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    // MARK: - Progress

    /// Frozen session denominator — see `ReviewSession.sessionProgressTotal`.
    private var sessionTotal: Int {
        max(session.sessionProgressTotal, 1)
    }

    /// 1-indexed position of the current card, clamped to the session total.
    private var cardPosition: Int {
        min(session.sessionStats.reviewed + 1, sessionTotal)
    }

    private var deckTone: Color {
        DeckTonePalette.tone(for: session.deckName)
    }

    /// Leaf deck name, with the parent path stripped. The backend hands
    /// back a "Parent::Child" path; the leaf alone is what a reviewer
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

    /// Palette for the review content. When auto-matching the card's
    /// background, the chrome must resolve light/dark against the *card*
    /// (not the system appearance) — otherwise dark-mode text lands on a
    /// light card, or vice-versa, and becomes unreadable. This mirrors the
    /// toolbar's `toolbarColorScheme` behaviour for the body below it.
    private var contentPalette: Palette {
        guard autoMatchCardBackground else { return palette }
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
                    CardContextMenu(cardId: cardId, noteId: session.currentNote?.id)
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

/// The card region of the reviewer: flip surface plus reveal/rating controls.
/// Extracted from `ReviewContent` so session mutations it doesn't read
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
            } else if session.requiresTypedAnswerInput {
                // No Space shortcut while the typed-answer field is active —
                // it would steal spaces from the user's input.
                revealButton
            } else {
                revealButton
                    .keyboardShortcut(.space, modifiers: [])
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
        .help("Show Answer (Space)")
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

    private var deckTone: Color {
        DeckTonePalette.tone(for: session.deckName)
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
            NativeCardView(
                content: isBack ? back : front,
                isAnswerSide: isBack,
                mediaFolder: mediaFolder,
                onQuestionCanvasTap: questionCanvasReveal,
                onTextLookup: textLookupCallback
            )
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
        nativeAudioPlayer.play(files: files, mediaFolder: mediaFolder)
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
private struct ReviewLookupQuery: Identifiable {
    let id = UUID()
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
