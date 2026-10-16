// `public import` because this file's `package init` exposes
// `ReaderSourceAnchor` in its signature.
public import AmgiReader
import AmgiReaderDictionary
import AmgiAppCore
import AnkiClients
import AnkiKit
import Dependencies
import BrowseFeature
import Sharing
package import SwiftUI
import AmgiUI

/// Sheet that renders dictionary lookup results for a query. First-pass
/// scope: plain-text glossaries, frequency strings, pitch positions, and
/// deinflection trace — no Yomitan structured-content rendering yet.
/// Calls `dictionaryLookupClient.lookup` directly; while the engine is a
/// stub it returns an empty placeholder and the view shows the empty
/// state.
package struct LookupPopupView: View {
    let initialQuery: String
    /// BCP-47 / loose hint forwarded into entry rows for TTS voice
    /// selection (`book.language`). Nil falls back to script sniffing.
    var languageHint: String? = nil
    /// The sentence the reader was reading when the user tapped, when the
    /// caller captured one. This is what lands in the note's sentence field —
    /// previously it was hard-coded to `nil`, so every card made from a
    /// lookup lost the context that motivated it.
    var contextSentence: String? = nil
    /// Durable pointer back to the tapped words, when the reader produced
    /// one. Forwarded into the note draft so a template can persist it.
    var sourceAnchor: ReaderSourceAnchor? = nil
    /// Extra Anki tags appended to every `AddNoteDraft` built from a
    /// dictionary entry while this popup is on screen. Used by the EPUB
    /// reader to source-tag cards (e.g. `amgi::book::<id>::ch::<idx>`)
    /// so the book detail screen can count cards per chapter without a
    /// schema change. Defaults to empty for existing callers.
    var extraTags: [String] = []
    /// Fires after `AddNoteView` reports a successful `addNote`. The
    /// EPUB reader uses this to post a `.amgiReaderCardAdded` notification
    /// so the book detail screen can refresh card counts live.
    var onAddedNote: (() -> Void)? = nil
    /// The book the lookup came from, so a one-tap card lands in that book's
    /// deck. Nil outside a book, which uses the last destination chosen.
    var bookID: String? = nil
    /// A one-tap card was written (note id, the tapped words' anchor, the
    /// term) or undone. The EPUB reader uses these to draw and erase the
    /// card mark on the page.
    var onCardCaptured: ((NoteID, ReaderSourceAnchor?, String) -> Void)? = nil
    var onCardRemoved: ((NoteID) -> Void)? = nil
    let onDismiss: () -> Void

    package init(
        initialQuery: String,
        languageHint: String? = nil,
        contextSentence: String? = nil,
        sourceAnchor: ReaderSourceAnchor? = nil,
        extraTags: [String] = [],
        onAddedNote: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.initialQuery = initialQuery
        self.languageHint = languageHint
        self.contextSentence = contextSentence
        self.sourceAnchor = sourceAnchor
        self.extraTags = extraTags
        self.onAddedNote = onAddedNote
        self.onDismiss = onDismiss
    }

    init(
        initialQuery: String,
        languageHint: String?,
        contextSentence: String?,
        sourceAnchor: ReaderSourceAnchor?,
        extraTags: [String],
        bookID: String?,
        onAddedNote: (() -> Void)?,
        onCardCaptured: ((NoteID, ReaderSourceAnchor?, String) -> Void)?,
        onCardRemoved: ((NoteID) -> Void)?,
        onDismiss: @escaping () -> Void
    ) {
        self.init(
            initialQuery: initialQuery,
            languageHint: languageHint,
            contextSentence: contextSentence,
            sourceAnchor: sourceAnchor,
            extraTags: extraTags,
            onAddedNote: onAddedNote,
            onDismiss: onDismiss
        )
        self.bookID = bookID
        self.onCardCaptured = onCardCaptured
        self.onCardRemoved = onCardRemoved
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = LookupPopupModel()

    @State private var query: String = ""
    @State private var pendingNoteDraft: NoteDraft?
    /// One-tap capture: writes the note without a sheet.
    @State private var capture = ReaderCardCapture()
    @State private var cardStates: [String: LookupCardButtonState] = [:]
    @State private var capturedNoteIDs: [String: NoteID] = [:]

    /// JSON-encoded `ReaderLookupNoteTemplate` stored in user prefs.
    /// Default is `.empty`, which makes `makeDraft` fall back to common
    /// Basic-notetype field names so the user still gets a usable draft
    /// before configuring the template.
    @Shared(.appStorage("reader_pref_lookup_note_template"))
    private var serializedTemplate: String = ""

    /// User-configurable in `ReaderDictionarySettingsView`. Defaults
    /// match DreamAfar (16 / 16) — large scan windows can stall lookups
    /// on big libraries, so we don't go higher without the user asking.
    @Shared(.appStorage(ReaderPreferences.Keys.dictionaryScanLength))
    private var scanLength: Int = 16
    @Shared(.appStorage(ReaderPreferences.Keys.dictionaryMaxResults))
    private var maxResults: Int = 16

    @Shared(.appStorage(ReaderPreferences.Keys.popupAudioSourceTemplate))
    private var audioTemplate: String = ""
    @Shared(.appStorage(ReaderPreferences.Keys.popupAudioPlaybackMode))
    private var audioPlaybackModeRaw: String = LookupAudioPlaybackMode.interrupt.rawValue
    @Shared(.appStorage(ReaderPreferences.Keys.popupAudioAutoplay))
    private var audioAutoplay: Bool = false

    // Styling prefs — see ReaderSettingsView for the controls.
    @Shared(.appStorage(ReaderPreferences.Keys.popupHeight))
    private var popupHeight: Double = 60          // % of screen
    @Shared(.appStorage(ReaderPreferences.Keys.popupFullWidth))
    private var popupFullWidth: Bool = false
    @Shared(.appStorage(ReaderPreferences.Keys.popupSwipeToDismiss))
    private var popupSwipeToDismiss: Bool = true
    @Shared(.appStorage(ReaderPreferences.Keys.popupCollapseDictionaries))
    private var popupCollapseDictionaries: Bool = false
    @Shared(.appStorage(ReaderPreferences.Keys.popupCompactGlossaries))
    private var popupCompactGlossaries: Bool = false
    @Shared(.appStorage(ReaderPreferences.Keys.popupFontSize))
    private var popupFontSize: Double = 17
    @Shared(.appStorage(ReaderPreferences.Keys.popupContentFontSize))
    private var popupContentFontSize: Double = 17
    @Shared(.appStorage(ReaderPreferences.Keys.popupKanaFontSize))
    private var popupKanaFontSize: Double = 15
    @Shared(.appStorage(ReaderPreferences.Keys.popupFrequencyFontSize))
    private var popupFrequencyFontSize: Double = 12
    @Shared(.appStorage(ReaderPreferences.Keys.popupDictionaryNameFontSize))
    private var popupDictionaryNameFontSize: Double = 11

    /// JSON-encoded `[String]` of recent queries, newest first. Capped at
    /// 20 entries to keep the suggestions list scannable; older queries
    /// fall off the end. Populated by `recordHistory` after a non-empty
    /// lookup; rendered via `.searchSuggestions` while the search field
    /// has focus.
    @Shared(.appStorage(ReaderPreferences.Keys.popupSearchHistory))
    private var serializedSearchHistory: String = "[]"

    /// JSON-encoded `[String]` of dictionary names the user has explicitly
    /// collapsed. Per-dict toggle state survives popup re-presentations
    /// and app restarts; the default-collapsed pref still controls the
    /// initial state for dictionaries not in this list.
    @Shared(.appStorage(ReaderPreferences.Keys.popupCollapsedDictionaries))
    private var serializedCollapsedDictionaries: String = "[]"

    @State private var autoplayedEntryID: String?
    /// Stack of follow-up queries the user pushed by tapping a word in
    /// a definition. The root popup shows the search field + initial
    /// query result; each entry on the path renders as a pushed
    /// `LookupChildPane`. Native nav back-swipe pops one level.
    @State private var lookupPath: [LookupPathEntry] = []

    package var body: some View {
        NavigationStack(path: $lookupPath) {
            content
                .navigationTitle("Lookup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDismiss() }
                    }
                }
                .searchable(text: $query, prompt: "Word or phrase")
                .searchSuggestions {
                    ForEach(searchHistory.prefix(8), id: \.self) { recent in
                        Text(recent)
                            .searchCompletion(recent)
                    }
                }
                .onSubmit(of: .search) {
                    Task { await performLookup() }
                }
                .task {
                    query = initialQuery
                    await performLookup()
                }
                .navigationDestination(for: LookupPathEntry.self) { pushed in
                    LookupChildPane(
                        query: pushed.query,
                        languageHint: languageHint,
                        styling: entryStyling,
                        audioTemplate: audioTemplate,
                        audioPlaybackMode: LookupAudioDefaults.resolvedPlaybackMode(audioPlaybackModeRaw),
                        scanLength: scanLength,
                        maxResults: maxResults,
                        collapsedDictionaries: collapsedDictionaries,
                        onSetCollapsed: { dict, collapsed in
                            setCollapsed(dict, collapsed: collapsed)
                        },
                        onMakeNote: { entry in
                            pendingNoteDraft = NoteDraft(draft: makeNoteDraft(for: entry))
                        },
                        onPushLookup: { phrase in
                            lookupPath.append(LookupPathEntry(query: phrase))
                        }
                    )
                }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(popupSwipeToDismiss ? .visible : .hidden)
    }

    /// Styling block derived from the user's popup prefs, shared by the
    /// root result list and every pushed child pane so the visual baseline
    /// is identical everywhere.
    private var entryStyling: LookupEntryStyling {
        LookupEntryStyling(
            termFontSize: popupFontSize + 3,
            readingFontSize: popupKanaFontSize,
            frequencyFontSize: popupFrequencyFontSize,
            dictionaryNameFontSize: popupDictionaryNameFontSize,
            contentFontSize: popupContentFontSize,
            collapseDictionaries: popupCollapseDictionaries,
            compactGlossaries: popupCompactGlossaries
        )
    }

    private var detents: Set<PresentationDetent> {
        guard horizontalSizeClass == .compact else { return [] }
        if popupFullWidth { return [.large] }
        let fraction = max(0.2, min(popupHeight / 100.0, 0.95))
        return [.fraction(fraction), .large]
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lookupError = model.lookupError {
            ContentUnavailableView {
                Label("Lookup failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(lookupError)
            } actions: {
                Button("Retry") { Task { await performLookup() } }
            }
        } else if let result = model.result, !result.entries.isEmpty {
            LookupResultList(
                result: result,
                styling: entryStyling,
                audioTemplate: audioTemplate,
                audioPlaybackMode: LookupAudioDefaults.resolvedPlaybackMode(audioPlaybackModeRaw),
                collapsedDictionaries: collapsedDictionaries,
                onSetCollapsed: { dict, collapsed in
                    setCollapsed(dict, collapsed: collapsed)
                },
                languageHint: languageHint,
                onMakeNote: { entry in
                    Task { await captureCard(for: entry) }
                },
                onLookupRequested: { tappedText in
                    lookupPath.append(LookupPathEntry(query: tappedText))
                },
                cardState: { cardStates[$0.id] ?? .ready },
                onEditNote: { entry in
                    pendingNoteDraft = NoteDraft(draft: makeNoteDraft(for: entry))
                }
            )
            .task(id: result.entries.map(\.id)) {
                await markExistingCards(in: result.entries)
            }
            .onAppear {
                // Autoplay first entry once per query — never re-fire
                // when the popup re-renders for SwiftUI state changes.
                if audioAutoplay,
                   let first = result.entries.first,
                   autoplayedEntryID != first.id {
                    autoplayedEntryID = first.id
                    Task {
                        await playAudio(term: first.term, reading: first.reading)
                    }
                }
            }
            .sheet(item: $pendingNoteDraft) { wrapped in
                AddNoteView(initialDraft: wrapped.draft) {
                    pendingNoteDraft = nil
                    onAddedNote?()
                }
            }
        } else if model.result?.isPlaceholder == true {
            ContentUnavailableView {
                Label("Engine not ready", systemImage: "hourglass")
            } description: {
                Text("Dictionary lookup engine is still a placeholder — full hoshidicts integration is pending.")
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: Search history persistence

    private var searchHistory: [String] {
        guard let data = serializedSearchHistory.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: Per-dictionary collapsed-state persistence

    private var collapsedDictionaries: Set<String> {
        guard let data = serializedCollapsedDictionaries.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

}

private extension LookupPopupView {
    func playAudio(term: String, reading: String?) async {
        guard let url = await LookupAudioResolver.resolve(
            term: term,
            reading: reading,
            template: audioTemplate
        ) else { return }
        await LookupAudioPlayer.shared.play(
            url: url,
            mode: LookupAudioDefaults.resolvedPlaybackMode(audioPlaybackModeRaw)
        )
    }

    func performLookup() async {
        // Reset autoplay tracking so a fresh query re-fires the first-entry
        // autoplay; the model owns the lookup I/O and reports the trimmed
        // query to record on a non-empty result.
        autoplayedEntryID = nil
        if let recorded = await model.runLookup(
            query: query,
            maxResults: maxResults,
            scanLength: scanLength
        ) {
            recordHistory(recorded)
        }
    }

    func recordHistory(_ entry: String) {
        var history = searchHistory.filter { $0 != entry }
        history.insert(entry, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        guard let data = try? JSONEncoder().encode(history),
              let json = String(data: data, encoding: .utf8) else { return }
        $serializedSearchHistory.withLock { $0 = json }
    }

    func setCollapsed(_ dictionary: String, collapsed: Bool) {
        var current = collapsedDictionaries
        if collapsed { current.insert(dictionary) } else { current.remove(dictionary) }
        guard let data = try? JSONEncoder().encode(Array(current).sorted()),
              let json = String(data: data, encoding: .utf8) else { return }
        $serializedCollapsedDictionaries.withLock { $0 = json }
    }

    /// Builds an `AddNoteDraft` for an entry by projecting the lookup
    /// payload through the user's saved `ReaderLookupNoteTemplate`. When
    /// the template hasn't been configured the projection falls back to
    /// common Basic-notetype field names so the user still gets a
    /// usable draft.
    /// One tap, no sheet. A tap on a card made here a moment ago undoes it,
    /// so a mis-tap costs a second tap rather than a trip to Browse.
    ///
    /// A configured lookup template wins, since the user mapped those fields
    /// on purpose. Without one, the card is a plain two-sided one in the
    /// book's deck — the term on the front, reading, definitions and the
    /// sentence on the back — instead of the old "Reader lookup" placeholder
    /// back. If writing fails for any reason the editor opens prefilled, so a
    /// capture is never a dead end.
    func captureCard(for entry: DictionaryLookupEntry) async {
        if cardStates[entry.id] == .added, let noteID = capturedNoteIDs[entry.id] {
            cardStates[entry.id] = .working
            await capture.remove(noteID)
            capturedNoteIDs[entry.id] = nil
            cardStates[entry.id] = .ready
            onCardRemoved?(noteID)
            return
        }
        cardStates[entry.id] = .working
        let draft = makeNoteDraft(for: entry)
        do {
            let destination = await capture.destination(forBook: bookID)
            let noteID: NoteID
            if draft.notetypeID != nil {
                noteID = try await capture.addMapped(draft, fallbackDeckID: destination?.deckID ?? 1)
            } else {
                guard let destination else { throw ReaderCardCapture.CaptureError.noDestination }
                let content = ReaderLookupCardContent(entry: entry, sentence: contextSentence)
                noteID = try await capture.addCard(
                    front: content.front,
                    back: content.back,
                    tags: draft.tags,
                    destination: destination
                )
            }
            capturedNoteIDs[entry.id] = noteID
            cardStates[entry.id] = .added
            onAddedNote?()
            onCardCaptured?(noteID, sourceAnchor, entry.term)
        } catch {
            cardStates[entry.id] = .ready
            pendingNoteDraft = NoteDraft(draft: draft)
        }
    }

    /// Marks entries whose term is already a card, before any tap, so the
    /// reader is not the one who discovers the duplicate in review.
    func markExistingCards(in entries: [DictionaryLookupEntry]) async {
        let template: ReaderLookupNoteTemplate = serializedTemplate.isEmpty
            ? .empty
            : ReaderLookupNoteTemplate.decode(from: serializedTemplate)
        let field: String?
        if !template.termField.isEmpty {
            field = template.termField
        } else if let destination = await capture.destination(forBook: bookID) {
            field = capture.notetype(destination.notetypeID)?.fieldNames.first
        } else {
            field = nil
        }
        guard let field else { return }
        for entry in entries.prefix(8) where cardStates[entry.id] == nil {
            if await capture.hasNote(field: field, matching: entry.term) {
                cardStates[entry.id] = .exists
            }
        }
    }

    func makeNoteDraft(for entry: DictionaryLookupEntry) -> AddNoteDraft {
        let template: ReaderLookupNoteTemplate = serializedTemplate.isEmpty
            ? .empty
            : ReaderLookupNoteTemplate.decode(from: serializedTemplate)

        let payload = ReaderLookupNotePayload(
            term: entry.term,
            reading: entry.reading,
            // The sentence the user actually tapped. Fall back to the term so
            // the field is never empty when the template references it, and
            // nil when there is genuinely no surrounding text.
            sentence: contextSentence?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            definitions: entry.glossaries.isEmpty
                ? ReaderLookupNotePayload.definitionsByDictionary(from: entry.structuredGlossaries)
                : entry.glossaries,
            dictionaries: entry.structuredGlossaries
                .map(\.dictionary)
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
                .nilIfBlank,
            frequency: entry.frequency,
            pitch: entry.pitch,
            deinflection: entry.deinflectionTrace.map(\.name).joined(separator: " → ").nilIfBlank,
            matched: entry.matched,
            source: entry.source,
            rules: entry.rules.joined(separator: ", ").nilIfBlank,
            sourceAnchor: sourceAnchor
        )

        var draft = template.makeDraft(
            payload: payload,
            fallbackDeckID: nil,
            sourceDescription: "Reader lookup"
        )
        if !extraTags.isEmpty {
            // Preserve template-derived tags; just append source-tags so
            // the book detail screen can count cards per chapter without
            // a schema change.
            draft.tags.append(contentsOf: extraTags)
        }
        return draft
    }
}

private struct NoteDraft: Identifiable {
    let id = UUID()
    let draft: AddNoteDraft
}

/// One entry in the popup's chained-lookup stack. UUID + query so two
/// pushes of the same word are still distinct in the navigation path
/// (Hashable identity).
struct LookupPathEntry: Hashable {
    let id = UUID()
    let query: String
}

/// Pushed view shown for follow-up lookups when the user taps a word
/// inside a definition. Owns its own lookup state so the root popup's
/// query stays intact — back-swipe restores it visually.
private struct LookupChildPane: View {
    let query: String
    let languageHint: String?
    let styling: LookupEntryStyling
    let audioTemplate: String
    let audioPlaybackMode: LookupAudioPlaybackMode
    let scanLength: Int
    let maxResults: Int
    let collapsedDictionaries: Set<String>
    let onSetCollapsed: (String, Bool) -> Void
    let onMakeNote: (DictionaryLookupEntry) -> Void
    let onPushLookup: (String) -> Void

    @State private var model = LookupPopupModel()

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lookupError = model.lookupError {
                ContentUnavailableView {
                    Label("Lookup failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(lookupError)
                }
            } else if let result = model.result, !result.entries.isEmpty {
                LookupResultList(
                    result: result,
                    styling: styling,
                    audioTemplate: audioTemplate,
                    audioPlaybackMode: audioPlaybackMode,
                    collapsedDictionaries: collapsedDictionaries,
                    onSetCollapsed: onSetCollapsed,
                    languageHint: languageHint,
                    onMakeNote: onMakeNote,
                    onLookupRequested: onPushLookup
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(query)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.runLookup(query: query, maxResults: maxResults, scanLength: scanLength)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    // Override just the lookup closure so the populated result list renders;
    // the popup's @Shared prefs fall back to their appStorage defaults.
    let _ = prepareDependencies {
        $0.dictionaryLookupClient.lookup = { text, _, _ in
            DictionaryLookupResult(
                query: text,
                entries: [
                    DictionaryLookupEntry(
                        term: text,
                        reading: "ねこ",
                        glossaries: ["a cat", "a feline kept as a pet"],
                        frequency: "1,240",
                        source: "JMdict"
                    ),
                ]
            )
        }
    }
    return LookupPopupView(initialQuery: "猫", onDismiss: {})
}
#endif
