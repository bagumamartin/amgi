import SwiftUI
import AmgiCardWeb
import AmgiTheme
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AnkiBackend
import AnkiKit
import Dependencies
import FeatureTemplates
import Sharing

/// Container: owns the `ReviewSession`, the review preferences, the sheet
/// selection state, and the session lifecycle (`start()`, audio-session
/// application, widget snapshot on disappear). Hands the session plus pref
/// values and sheet bindings to the pure `ReviewContent`, which is what the
/// `#Preview`s build with a stub session.
struct ReviewView: View {
    let deckId: DeckID
    let onDismiss: () -> Void

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
    @State private var cardActions = CardContextMenuModel()
    @State private var confirmDeleteNote = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showRemainingDays {
                    progressBar
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
                    editingNote = session.currentNote
                } label: {
                    Label("Edit Note", systemImage: "pencil")
                }
                .disabled(session.currentNote == nil)

                Button {
                    editingTemplate = session.currentTemplateTarget
                } label: {
                    Label("Edit Template", systemImage: "square.and.pencil")
                }
                .disabled(session.currentTemplateTarget == nil)

                Button {
                    // Empty initial query opens the popup focused for typing.
                    // Future enhancement: forward CardWebView text-selection so
                    // the query is pre-populated.
                    lookupQuery = ""
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

// MARK: - Card Area

/// The card region of the reviewer: render-mode chip, the flip surface, and
/// the reveal/rating controls. Extracted from `ReviewContent` so that session
/// mutations it doesn't read (audio-playing toggles, toast, deck counts) skip
/// its body — otherwise every such change re-runs `CardWebView.updateUIView`
/// and its regex HTML processing. Owns the render-mode sheet flag and the
/// native audio player, which are only relevant here.
private struct ReviewCardArea: View {
    let session: ReviewSession
    let openLinksExternally: Bool
    let cardContentAlignment: String
    let tapLookup: Bool
    let showNextReviewTime: Bool
    @Binding var lookupQuery: String?

    @Environment(\.palette) private var palette
    @State private var showRenderModeSheet = false
    @State private var nativeAudioPlayer = NativeCardAudioPlayer()

    /// Fixed for the collection's lifetime, so it's resolved once into `@State`
    /// rather than re-resolving the dependency on every `cardSurface` call —
    /// which the flip container makes twice per `body` pass.
    @State private var mediaFolder: URL? = {
        @Dependency(\.ankiBackend) var backend
        guard let path = backend.currentMediaFolderPath else { return nil }
        return URL(fileURLWithPath: path)
    }()

    var body: some View {
        VStack(spacing: 0) {
            RenderModeChipRow(
                isNative: isNativeMode,
                isAuto: session.resolvedByAuto,
                templateName: session.templateName,
                onTap: { showRenderModeSheet = true }
            )
            .padding(.horizontal)
            .padding(.vertical, 4)

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
            .sheet(isPresented: $showRenderModeSheet) { renderModeSheet }

            Spacer()

            if session.requiresTypedAnswerInput {
                TypedAnswerField(session: session)
            }

            if session.showAnswer {
                answerButtons
            } else {
                Button {
                    session.revealAnswer()
                } label: {
                    Text("Show Answer")
                        .amgiFont(.bodyEmphasis)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isAdvancing)
                .padding()
            }
        }
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

    private var renderModeSheet: some View {
        RenderModeSheet(
            explainer: renderModeExplainer,
            template: session.currentTemplateTarget,
            templateName: session.templateName,
            onChanged: { session.reresolveCurrentCard() }
        )
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

    @ViewBuilder
    private func cardSurface(isBack: Bool) -> some View {
        switch session.resolvedMode {
        case .native(let front, let back):
            NativeCardView(
                content: isBack ? back : front,
                isAnswerSide: isBack,
                mediaFolder: mediaFolder
            )
        case .html:
            VStack(spacing: 0) {
                webChromeStrip
                CardWebView(
                    html: isBack ? session.backHTML : session.frontHTML,
                    cardCSS: session.cardCSS,
                    isAnswerSide: isBack,
                    cardOrdinal: session.currentCardOrdinal,
                    replayRequestID: session.replayRequestID,
                    stopAudioRequestID: session.stopAudioRequestID,
                    openLinksExternally: openLinksExternally,
                    contentAlignment: CardWebViewContentAlignment(rawValue: cardContentAlignment) ?? .center,
                    onAudioStateChange: { playing in session.updateAudioPlaying(playing) },
                    onCardBackgroundColorChange: { color, isDark in
                        session.updateCardChrome(color: color, isDark: isDark)
                    },
                    // No tap-lookup while the typed-answer input is up — the
                    // dictionary would hand over the answer to be typed.
                    onLookupRequested: tapLookup && !session.requiresTypedAnswerInput ? { text, _, _ in
                        if let text, !text.isEmpty { lookupQuery = text }
                    } : nil
                )
            }
        }
    }

    /// Slim chrome above the sandboxed WebView card (R11): HTML badge ·
    /// template name · "sandboxed".
    private var webChromeStrip: some View {
        HStack(spacing: 8) {
            Text("HTML")
                .amgiFont(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(palette.warning)
            if let name = session.templateName {
                Text(name)
                    .amgiFont(.micro, .monospaced)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text("sandboxed")
                .amgiFont(.caption)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
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
