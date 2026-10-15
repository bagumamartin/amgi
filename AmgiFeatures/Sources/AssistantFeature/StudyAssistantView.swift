public import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import ManifoldKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The assistant chat. Presented as a sheet by the scene; the context it is
/// opened with becomes the chat's scope and decides its suggestions.
public struct StudyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.assistantSceneNavigation) private var sceneNavigation
    @State private var engine: AssistantEngine?
    @State private var loadError: String?
    private let initialPrompt: String?
    private let context: AssistantContext
    private let onRoute: (@MainActor (AssistantRoute) -> Void)?
    private let onOpenNote: (@MainActor (AssistantCitation) -> Void)?
    private let onClose: (@MainActor () -> Void)?
    private let onNoteSaved: (@MainActor () -> Void)?

    public init(
        initialPrompt: String? = nil, context: AssistantContext = AssistantContext(),
        onRoute: (@MainActor (AssistantRoute) -> Void)? = nil,
        onOpenNote: (@MainActor (AssistantCitation) -> Void)? = nil,
        onClose: (@MainActor () -> Void)? = nil,
        onNoteSaved: (@MainActor () -> Void)? = nil
    ) {
        self.initialPrompt = initialPrompt; self.context = context
        self.onRoute = onRoute; self.onOpenNote = onOpenNote; self.onClose = onClose
        self.onNoteSaved = onNoteSaved
    }

    public var body: some View {
        Group {
            if let engine {
                AssistantChatView(engine: engine, launchContext: context, openNote: { citation in
                    engine.stop(); close(); (onOpenNote ?? sceneNavigation.note)(citation)
                }, close: { engine.stop(); close() })
            } else if let loadError {
                ContentUnavailableView("Assistant could not open", systemImage: "exclamationmark.bubble", description: Text(loadError))
                    .overlay(alignment: .topTrailing) { Button("Close", action: close).padding() }
            } else {
                AssistantHead(.sleeping).frame(width: 64, height: 64)
            }
        }
        .task {
            guard engine == nil else { return }
            do {
                let created = try AssistantEngine(context: context)
                let routeHandler = onRoute ?? sceneNavigation.route
                let dismissAction = dismiss
                let explicitClose = onClose
                created.toolbox.open = { route in
                    if let explicitClose { explicitClose() } else { dismissAction() }
                    routeHandler(route)
                }
                if let onNoteSaved { created.toolbox.noteSaved = onNoteSaved }
                engine = created
                await created.prepare()
                if let initialPrompt, !initialPrompt.isEmpty { created.draft = initialPrompt }
            } catch { loadError = error.localizedDescription }
        }
        .onDisappear { engine?.stop() }
        .onChange(of: AccountStore.shared.selectionID) { engine?.stop(); close() }
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }
}

// MARK: - Chat

struct AssistantChatView: View {
    @Bindable var engine: AssistantEngine
    let launchContext: AssistantContext
    let openNote: (AssistantCitation) -> Void
    let close: () -> Void
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var showHistory = false
    @State private var renaming: ChatSession?
    @State private var newTitle = ""
    @State private var previewSource: AssistantSource?

    /// What the head is doing: a fresh reaction wins, then the turn's phase,
    /// then whether the user is typing.
    private var mood: AssistantMood {
        if let reaction = engine.reaction { return reaction }
        switch engine.phase {
        case .thinking: return .thinking
        case .working: return .searching
        case .reviewing: return .curious
        case .responding: return .responding
        case .idle: return focused ? .listening : .idle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
                        if engine.turns.isEmpty {
                            welcome
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .containerRelativeFrame(.vertical, alignment: .bottomLeading) { length, _ in max(0, length - 24) }
                        }
                        ForEach(engine.turns) { turn in
                            TurnView(
                                turn: turn,
                                isLatest: turn.id == engine.turns.last?.id,
                                phase: engine.phase,
                                mood: mood,
                                openSource: open
                            )
                        }
                        if let error = engine.errorMessage {
                            Text(error).amgiFont(.caption).foregroundStyle(palette.warning)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, AmgiSpacing.cardInset)
                    .padding(.vertical, AmgiSpacing.lg)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: engine.turns.last?.reply) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: engine.turns.last?.steps.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .background(palette.surface)
        .sheet(isPresented: $showHistory) { AssistantHistory(engine: engine) }
        .sheet(item: $previewSource) { AssistantSourcePreview(source: $0, profile: engine.profile) }
        .sheet(item: Binding(get: { engine.pendingDraft }, set: { if $0 == nil { engine.resolveReview(nil) } })) { draft in
            AssistantFlashcardReview(draft: draft) { engine.resolveReview($0) }
                .interactiveDismissDisabled()
        }
        .sheet(item: Binding(get: { engine.pendingFix }, set: { if $0 == nil { engine.resolveFix(nil) } })) { draft in
            AssistantNoteFixReview(draft: draft) { engine.resolveFix($0) }
                .interactiveDismissDisabled()
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                if let session = renaming { Task { await engine.rename(session, title: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity)
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AmgiSpacing.md) {
            Menu { chatMenu } label: {
                Image(systemName: "line.3.horizontal")
                    .modifier(HeaderButton())
            }
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.button)
            #endif
            .buttonStyle(.plain)
            .accessibilityLabel("Chats")
            Spacer(minLength: 0)
            Text(engine.title)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            if !engine.turns.isEmpty {
                Button { engine.newChat() } label: {
                    Image(systemName: "square.and.pencil").modifier(HeaderButton())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat")
            }
            Button(action: close) {
                Image(systemName: "xmark").modifier(HeaderButton())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("assistant.close")
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.top, AmgiSpacing.lg)
        .padding(.bottom, AmgiSpacing.sm)
    }

    @ViewBuilder private var chatMenu: some View {
        Section("Recent chats") {
            ForEach(engine.history.displayedSessions.prefix(5)) { session in
                Button { Task { await engine.select(session) } } label: {
                    if session.id == engine.activeSession?.id {
                        Label(session.title, systemImage: "checkmark")
                    } else {
                        Text(session.title)
                    }
                }
            }
            Button("All chats…", systemImage: "clock.arrow.circlepath") { focused = false; showHistory = true }
        }
        if let session = engine.activeSession {
            Section("This chat") {
                Button("Rename…", systemImage: "pencil") { newTitle = session.title; renaming = session }
                Button("Copy conversation", systemImage: "doc.on.doc") { copy(engine.transcript) }
                if engine.scope != launchContext {
                    Button("Ask about \(launchContext.title)", systemImage: "viewfinder") { engine.useContext(launchContext) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await engine.delete(session) } }
            }
        }
        Button("New chat", systemImage: "square.and.pencil") { engine.newChat() }
    }

    // MARK: Empty state

    private var welcome: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
            AssistantHead(mood, gaze: focused ? CGPoint(x: 0.15, y: 0.75) : nil)
                .frame(width: 92, height: 92)
            Text(greeting)
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            if engine.availability != .ready {
                Label(engine.availability.detail, systemImage: "lock.shield")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                Text("Suggestions")
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.bottom, AmgiSpacing.xs)
                ForEach(ChatSuggestion.for(engine.scope)) { suggestion in
                    Button { use(suggestion) } label: {
                        Label {
                            Text(suggestion.title).foregroundStyle(palette.textPrimary)
                        } icon: {
                            Image(systemName: suggestion.icon).foregroundStyle(palette.accent)
                        }
                        .amgiFont(.body)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.isBusy)
                }
            }
        }
    }

    private var greeting: String {
        switch engine.scope.kind {
        case "deck": L10n.text("What shall we do with \(engine.scope.title)?")
        case "reader": L10n.text("Reading \(engine.scope.title)?")
        case "note", "review": L10n.text("Let's dig into this card.")
        default: L10n.text("What are we learning today?")
        }
    }

    private func use(_ suggestion: ChatSuggestion) {
        if suggestion.sends {
            focused = false
            engine.send(suggestion.prompt)
        } else {
            engine.draft = suggestion.prompt
            focused = true
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            ContextChip(scope: engine.scope) {
                engine.useContext(AssistantContext())
            }
            TextField("Ask anything", text: $engine.draft, axis: .vertical)
                .amgiFont(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
                .accessibilityIdentifier("assistant.composer")
            HStack {
                Spacer()
                Button {
                    if engine.isBusy { engine.stop() } else { send() }
                } label: {
                    Image(systemName: engine.isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend || engine.isBusy ? palette.background : palette.textTertiary)
                        .frame(width: 36, height: 36)
                        .background(canSend || engine.isBusy ? palette.textPrimary : palette.separator, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !engine.isBusy)
                .accessibilityLabel(engine.isBusy ? "Stop" : "Send")
            }
        }
        .padding(AmgiSpacing.lg)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 1)
        }
        .amgiChromeShadow(RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous), radius: 16, y: 6, opacity: 0.08)
        .padding(.horizontal, AmgiSpacing.md)
        .padding(.bottom, AmgiSpacing.sm)
    }

    private var canSend: Bool {
        !engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        engine.send()
    }

    private func open(_ source: AssistantSource) {
        if let id = source.noteID {
            openNote(AssistantCitation(id: id, title: source.title, profile: engine.profile))
        } else {
            previewSource = source
        }
    }
}

private func copy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

private struct HeaderButton: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
            .frame(width: 44, height: 44)
            .amgiMaterial(.regular, in: Circle(), interactive: true)
            .contentShape(Circle())
    }
}

// MARK: - Context chip

/// What the chat is about. Tap the × to widen it to the whole collection.
private struct ContextChip: View {
    let scope: AssistantContext
    let clear: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(scope.kind == "collection" ? L10n.text("Collection") : scope.title)
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textTertiary)
            }
            if scope.kind != "collection" {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.textTertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask about the whole collection instead")
            }
        }
        .padding(.leading, AmgiSpacing.xs)
        .padding(.trailing, AmgiSpacing.sm)
        .padding(.vertical, AmgiSpacing.xs)
        .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch scope.kind {
        case "deck": "rectangle.stack"
        case "note": "note.text"
        case "reader": "book"
        case "review": "rectangle.on.rectangle"
        default: "books.vertical"
        }
    }

    private var subtitle: String {
        switch scope.kind {
        case "deck": L10n.text("This deck")
        case "note": L10n.text("This note")
        case "reader": L10n.text("This book")
        case "review": L10n.text("In review")
        default: L10n.text("All decks")
        }
    }
}

// MARK: - Turns

private struct TurnView: View {
    let turn: AssistantEngine.Turn
    let isLatest: Bool
    let phase: AssistantEngine.Phase
    let mood: AssistantMood
    let openSource: (AssistantSource) -> Void
    @Environment(\.palette) private var palette

    private var isLive: Bool { isLatest && phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.md) {
            Text(turn.prompt)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, AmgiSpacing.lg)
                .padding(.vertical, AmgiSpacing.md)
                .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.card - 4, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)

            if isLatest {
                HStack(spacing: AmgiSpacing.sm) {
                    AssistantHead(mood).frame(width: 28, height: 28)
                    if isLive, turn.reply.isEmpty {
                        Text(liveLabel)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                            .contentTransition(.opacity)
                    }
                }
            }

            ForEach(turn.steps) { step in StepRow(step: step) }

            if !turn.reply.isEmpty {
                Text(Self.render(turn.reply))
                    .amgiFont(.body)
                    .foregroundStyle(palette.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.warning)
            } else if turn.stopped {
                Label("Stopped", systemImage: "stop.circle")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
            }

            if !turn.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AmgiSpacing.sm) {
                        ForEach(turn.sources) { source in
                            Button { openSource(source) } label: {
                                Label(source.title, systemImage: source.noteID != nil ? "note.text" : "doc.text")
                                    .amgiFont(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(palette.textPrimary)
                                    .padding(.horizontal, AmgiSpacing.md)
                                    .padding(.vertical, AmgiSpacing.sm)
                                    .background(palette.background, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !turn.reply.isEmpty, !isLive {
                HStack(spacing: AmgiSpacing.lg) {
                    Button { copy(turn.reply) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy")
                    ShareLink(item: turn.reply) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(palette.textTertiary)
            }
        }
    }

    private var liveLabel: String {
        switch phase {
        case .thinking: L10n.text("Thinking…")
        case .working: L10n.text("Working on it…")
        case .reviewing: L10n.text("Waiting for your review")
        case .responding, .idle: ""
        }
    }

    static func render(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct StepRow: View {
    let step: AssistantStep
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.sm) {
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: step.icon).foregroundStyle(palette.positive)
                case .declined: Image(systemName: "hand.raised").foregroundStyle(palette.textTertiary)
                case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(palette.warning)
                }
            }
            .frame(width: 18)
            Text(step.text)
                .foregroundStyle(step.state == .failed ? palette.warning : palette.textSecondary)
        }
        .amgiFont(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - History

private struct AssistantHistory: View {
    let engine: AssistantEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            List {
                ForEach(engine.history.displayedSessions) { session in
                    Button {
                        Task { await engine.select(session); dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
                            Text(session.title).amgiFont(.body).foregroundStyle(palette.textPrimary).lineLimit(1)
                            Text(session.updatedAt, style: .relative).amgiFont(.micro).foregroundStyle(palette.textTertiary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await engine.delete(session) } }
                    }
                }
            }
            .overlay {
                if engine.history.displayedSessions.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Suggestions

struct ChatSuggestion: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let prompt: String
    /// Sends at once; otherwise fills the composer for the user to finish.
    let sends: Bool

    static func `for`(_ scope: AssistantContext) -> [ChatSuggestion] {
        switch scope.kind {
        case "deck":
            [
                .init(title: L10n.text("How much is due here?"), icon: "calendar", prompt: L10n.text("How much is due in \(scope.title) today?"), sends: true),
                .init(title: L10n.text("Add cards to this deck…"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards for \(scope.title) about "), sends: false),
                .init(title: L10n.text("Quiz me on this deck"), icon: "questionmark.bubble", prompt: L10n.text("Ask me one question at a time about \(scope.title)."), sends: true),
                .init(title: L10n.text("Start reviewing"), icon: "play.rectangle", prompt: L10n.text("Start reviewing \(scope.title)."), sends: true),
            ]
        case "note", "review":
            [
                .init(title: L10n.text("Explain this card"), icon: "lightbulb", prompt: L10n.text("Explain this card simply."), sends: true),
                .init(title: L10n.text("Give me a memory trick"), icon: "sparkle.magnifyingglass", prompt: L10n.text("Give me a mnemonic for this card."), sends: true),
                .init(title: L10n.text("Make related cards"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make two flashcards related to this card."), sends: true),
                .init(title: L10n.text("Fix a mistake in this card…"), icon: "pencil", prompt: L10n.text("Fix this card: "), sends: false),
            ]
        case "reader":
            [
                .init(title: L10n.text("Summarize this chapter"), icon: "text.alignleft", prompt: L10n.text("Summarize this chapter in a few sentences."), sends: true),
                .init(title: L10n.text("Make cards from this chapter"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards from the key ideas in this chapter."), sends: true),
                .init(title: L10n.text("Explain a passage…"), icon: "text.quote", prompt: L10n.text("Explain this passage: "), sends: false),
            ]
        default:
            [
                .init(title: L10n.text("What should I study today?"), icon: "calendar", prompt: L10n.text("What should I study today?"), sends: true),
                .init(title: L10n.text("Make flashcards about…"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards about "), sends: false),
                .init(title: L10n.text("Find notes about…"), icon: "magnifyingglass", prompt: L10n.text("Find my notes about "), sends: false),
                .init(title: L10n.text("Quiz me"), icon: "questionmark.bubble", prompt: L10n.text("Quiz me with one question about something in my collection."), sends: true),
            ]
        }
    }
}
