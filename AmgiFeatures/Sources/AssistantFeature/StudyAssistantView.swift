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
/// opened with become its context chips and decide its suggestions.
public struct StudyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.assistantSceneNavigation) private var sceneNavigation
    @State private var engine: AssistantEngine?
    @State private var loadError: String?
    private let initialPrompt: String?
    private let contexts: [AssistantContext]
    private let onRoute: (@MainActor (AssistantRoute) -> Void)?
    private let onOpenNote: (@MainActor (AssistantCitation) -> Void)?
    private let onClose: (@MainActor () -> Void)?
    private let onNoteSaved: (@MainActor () -> Void)?

    public init(
        initialPrompt: String? = nil, contexts: [AssistantContext] = [.collection],
        onRoute: (@MainActor (AssistantRoute) -> Void)? = nil,
        onOpenNote: (@MainActor (AssistantCitation) -> Void)? = nil,
        onClose: (@MainActor () -> Void)? = nil,
        onNoteSaved: (@MainActor () -> Void)? = nil
    ) {
        self.initialPrompt = initialPrompt; self.contexts = contexts
        self.onRoute = onRoute; self.onOpenNote = onOpenNote; self.onClose = onClose
        self.onNoteSaved = onNoteSaved
    }

    public var body: some View {
        Group {
            if let engine {
                AssistantChatView(engine: engine, openNote: { citation in
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
                let created = try AssistantEngine(contexts: contexts)
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
    let openNote: (AssistantCitation) -> Void
    let close: () -> Void
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var showHistory = false
    @State private var renaming: ChatSession?
    @State private var newTitle = ""
    @State private var previewSource: AssistantSource?
    @State private var showContextPicker = false
    @State private var showConnections = false

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
            AssistantComposer(
                engine: engine, focused: $focused, send: send,
                showContextPicker: { focused = false; showContextPicker = true },
                showConnections: { focused = false; showConnections = true }
            )
        }
        .background(palette.surface)
        .animation(AmgiMotion.quick, value: engine.contexts)
        .animation(AmgiMotion.quick, value: engine.attachments)
        .sheet(isPresented: $showHistory) { AssistantHistory(engine: engine) }
        .sheet(isPresented: $showContextPicker) { AssistantContextPicker(engine: engine) }
        .sheet(isPresented: $showConnections) { AssistantConnectionsSheet() }
        .modifier(ChatGPTPlanWelcome(store: engine.providers))
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
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await engine.delete(session) } }
            }
        }
        Button("New chat", systemImage: "square.and.pencil") { engine.newChat() }
        Section("Model: \(engine.model.name)") {
            Button("AI Connections…", systemImage: "link") { focused = false; showConnections = true }
        }
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
            } else if !engine.model.provider.isCloud {
                Label("Private, on this device", systemImage: "lock.shield")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
            }
            VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                Text("Suggestions")
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.bottom, AmgiSpacing.xs)
                ForEach(ChatSuggestion.for(engine.contexts.first)) { suggestion in
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
        guard let first = engine.contexts.first else { return L10n.text("What are we learning today?") }
        return switch first.type {
        case .deck: L10n.text("What shall we do with \(first.title)?")
        case .book, .chapter: L10n.text("Reading \(first.title)?")
        case .page: L10n.text("What's on \(first.title.lowercased())?")
        case .passage: L10n.text("Let's look at this passage.")
        case .note, .review: L10n.text("Let's dig into this card.")
        case .collection: L10n.text("What are we learning today?")
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

            if !turn.info.files.isEmpty {
                HStack(spacing: AmgiSpacing.sm) {
                    ForEach(turn.info.files) { file in
                        AssistantAttachmentChip(name: file.name, kind: file.kind, thumbnail: file.thumbnail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

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
                AssistantMarkdown(text: turn.reply)
            }

            if turn.usageLimited {
                ChatGPTUsageLimitCard()
            } else if let error = turn.error {
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
                    if let model = turn.info.model {
                        Text(model)
                            .amgiFont(.micro)
                            .lineLimit(1)
                    }
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

    static func `for`(_ scope: AssistantContext?) -> [ChatSuggestion] {
        guard let scope else { return general }
        return switch scope.type {
        case .deck:
            [
                .init(title: L10n.text("How much is due here?"), icon: "calendar", prompt: L10n.text("How much is due in \(scope.title) today?"), sends: true),
                .init(title: L10n.text("Add cards to this deck…"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards for \(scope.title) about "), sends: false),
                .init(title: L10n.text("Quiz me on this deck"), icon: "questionmark.bubble", prompt: L10n.text("Ask me one question at a time about \(scope.title)."), sends: true),
                .init(title: L10n.text("Start reviewing"), icon: "play.rectangle", prompt: L10n.text("Start reviewing \(scope.title)."), sends: true),
            ]
        case .note, .review:
            [
                .init(title: L10n.text("Explain this card"), icon: "lightbulb", prompt: L10n.text("Explain this card simply."), sends: true),
                .init(title: L10n.text("Give me a memory trick"), icon: "sparkle.magnifyingglass", prompt: L10n.text("Give me a mnemonic for this card."), sends: true),
                .init(title: L10n.text("Make related cards"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make two flashcards related to this card."), sends: true),
                .init(title: L10n.text("Fix a mistake in this card…"), icon: "pencil", prompt: L10n.text("Fix this card: "), sends: false),
            ]
        case .passage:
            [
                .init(title: L10n.text("Explain this passage"), icon: "lightbulb", prompt: L10n.text("Explain this passage in plain words."), sends: true),
                .init(title: L10n.text("Define the hard words"), icon: "character.book.closed", prompt: L10n.text("List and define the difficult words in this passage."), sends: true),
                .init(title: L10n.text("Make cards from it"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards from this passage."), sends: true),
                .init(title: L10n.text("Translate it"), icon: "globe", prompt: L10n.text("Translate this passage into "), sends: false),
            ]
        case .chapter, .book:
            [
                .init(title: L10n.text("Summarize this chapter"), icon: "text.alignleft", prompt: L10n.text("Summarize this chapter in a few sentences."), sends: true),
                .init(title: L10n.text("Make cards from this chapter"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards from the key ideas in this chapter."), sends: true),
                .init(title: L10n.text("Quiz me on it"), icon: "questionmark.bubble", prompt: L10n.text("Ask me one question at a time about this chapter."), sends: true),
                .init(title: L10n.text("Explain a passage…"), icon: "text.quote", prompt: L10n.text("Explain this passage: "), sends: false),
            ]
        case .page:
            [
                .init(title: L10n.text("Summarize this page"), icon: "text.alignleft", prompt: L10n.text("Summarize this page in a few sentences."), sends: true),
                .init(title: L10n.text("Make cards from this page"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards from the key ideas on this page."), sends: true),
                .init(title: L10n.text("Explain a passage…"), icon: "text.quote", prompt: L10n.text("Explain this passage: "), sends: false),
            ]
        case .collection:
            general
        }
    }

    static var general: [ChatSuggestion] {
        [
                .init(title: L10n.text("What should I study today?"), icon: "calendar", prompt: L10n.text("What should I study today?"), sends: true),
                .init(title: L10n.text("Make flashcards about…"), icon: "rectangle.stack.badge.plus", prompt: L10n.text("Make flashcards about "), sends: false),
                .init(title: L10n.text("Find notes about…"), icon: "magnifyingglass", prompt: L10n.text("Find my notes about "), sends: false),
                .init(title: L10n.text("Quiz me"), icon: "questionmark.bubble", prompt: L10n.text("Quiz me with one question about something in my collection."), sends: true),
            ]
    }
}
