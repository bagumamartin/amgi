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

/// Scene-owned presentation, backed by Manifold's conversation, persistence,
/// tool and message surfaces. Suggestions arrive before keyboard focus.
public struct StudyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.assistantSceneNavigation) private var sceneNavigation
    @State private var runtime: AssistantRuntime?
    @State private var loadError: String?
    @State private var fallback = StudyAssistantModel()
    private let initialPrompt: String?
    private let context: AssistantContext
    private let onRoute: (@MainActor (AssistantRoute) -> Void)?
    private let onOpenNote: (@MainActor (AssistantCitation) -> Void)?
    private let onClose: (@MainActor () -> Void)?
    public init(initialPrompt: String? = nil, context: AssistantContext = AssistantContext(), onRoute: (@MainActor (AssistantRoute) -> Void)? = nil, onOpenNote: (@MainActor (AssistantCitation) -> Void)? = nil, onClose: (@MainActor () -> Void)? = nil) {
        self.initialPrompt = initialPrompt; self.context = context; self.onRoute = onRoute; self.onOpenNote = onOpenNote
        self.onClose = onClose
    }
    public var body: some View {
        Group {
            if let runtime {
                AssistantSurface(runtime: runtime, fallback: fallback, currentContext: context, openNote: { citation in
                    runtime.stop(); close(); (onOpenNote ?? sceneNavigation.note)(citation)
                }, close: { runtime.stop(); close() })
                    .environment(runtime.chat)
            } else if let loadError {
                ContentUnavailableView("Assistant could not open", systemImage: "exclamationmark.bubble", description: Text(loadError))
                    .overlay(alignment: .topTrailing) { Button("Close", action: close).padding() }
            } else { ProgressView("Opening assistant…") }
        }
        .task {
            guard runtime == nil else { return }
            do {
                let created = try AssistantRuntime(context: context)
                let routeHandler = onRoute ?? sceneNavigation.route
                let dismissAction = dismiss
                let explicitClose = onClose
                created.host.openRoute = { route in
                    if let explicitClose { explicitClose() } else { dismissAction() }
                    routeHandler(route)
                }
                runtime = created
                await created.prepare(initialPrompt: initialPrompt)
                await fallback.prepare()
            } catch { loadError = error.localizedDescription }
        }
        .onDisappear { runtime?.stop() }
        .onChange(of: AccountStore.shared.selectionID) { runtime?.stop(); close() }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
}

private struct AssistantSurface: View {
    @Bindable var runtime: AssistantRuntime
    @Bindable var fallback: StudyAssistantModel
    let currentContext: AssistantContext
    let openNote: (AssistantCitation) -> Void
    let close: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var showHistory = false
    @State private var preferenceRevision = 0
    @State private var fallbackTask: Task<Void, Never>?
    @State private var selectedSource: AssistantSource?
    private var isReady: Bool { _ = preferenceRevision; return runtime.provider.availability == .ready }
    private var isGenerating: Bool { runtime.chat.isGenerating || fallback.isThinking }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if runtime.chat.messages.isEmpty {
                            welcome
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .containerRelativeFrame(.vertical) { length, _ in max(0, length - 40) }
                        }
                        ForEach(runtime.chat.messages) { message in
                            if message.role == .user && message.status == .failed {
                                // Route retry through the same cross-window turn
                                // lease as Send, including deterministic mode.
                                VStack(alignment: .trailing, spacing: 8) {
                                    Text(message.content).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                                    Button("Retry sending", systemImage: "arrow.clockwise") {
                                        if isReady { runtime.retry(message.id) }
                                        else { runtime.chat.inputText = message.content; send() }
                                    }.disabled(isGenerating)
                                }.frame(maxWidth: .infinity, alignment: .trailing).id(message.id)
                            } else {
                            MessageBubbleView(message: message, isStreaming: runtime.chat.isGenerating && message.id == runtime.chat.messages.last?.id, session: runtime.chat.activeSession)
                                .toolInvocationStyle(AssistantToolStatusStyle())
                                .chatMessagePartRenderer { parameters in
                                    if parameters.role == .assistant, case .text(let text) = parameters.part, !text.contains("```") {
                                        // SwiftUI Text does not lay out the full
                                        // Markdown parser's paragraph intents.
                                        // Preserve actual line/paragraph breaks
                                        // while retaining inline emphasis/links.
                                        let rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
                                        return AnyView(Text(rendered).font(.body).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled))
                                    }
                                    return parameters.defaultPartView()
                                }
                                .contextMenu {
                                    Button("Copy", systemImage: "doc.on.doc") { copy(message.content) }
                                    ShareLink(item: message.content)
                                }.id(message.id)
                            }
                        }
                        if !runtime.host.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sources").font(.caption).foregroundStyle(.secondary)
                                ForEach(runtime.host.sources) { source in
                                    Button {
                                        if let id = source.noteID { openNote(AssistantCitation(id: id, title: source.title, profile: runtime.profile)) }
                                        else { selectedSource = source }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Label(source.title, systemImage: source.noteID != nil ? "note.text" : "doc.text.magnifyingglass")
                                            if !source.anchor.isEmpty { Text(source.anchor).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if runtime.wasInterrupted && !isGenerating {
                            Label("The previous response was stopped. You can continue this chat.", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(runtime.host.receipts.filter { $0.chatID == runtime.chat.activeSession?.id }.suffix(3)) { receipt in
                            Label("\(receipt.operation.replacingOccurrences(of: "_", with: " ")): \(receipt.outcome)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                        }
                        if isGenerating { Label(runtime.provider.activityDescription, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
                        if let error = runtime.chat.errorMessage ?? runtime.errorMessage ?? fallback.errorMessage {
                            Text(error).font(.callout).foregroundStyle(palette.warning)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: runtime.chat.messages.last?.content) {
                    if !focused { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
            composer
        }
        .background(palette.surface)
        .sheet(isPresented: $showHistory) { AssistantHistory(runtime: runtime) }
        .sheet(item: $selectedSource) { AssistantSourcePreview(source: $0, profile: runtime.profile) }
        .sheet(isPresented: Binding(get: { runtime.host.pendingTitle != nil }, set: { if !$0 { runtime.host.resolve(approve: false) } })) {
            AssistantChangeReview(host: runtime.host)
                .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            preferenceRevision += 1
            if runtime.provider.availability != .ready { runtime.stop() }
        }
        .onChange(of: runtime.chat.inputText) { runtime.persistDraft() }
        .onChange(of: runtime.host.sources) { runtime.persistSources() }
        .onChange(of: runtime.chat.activeSession?.id) { fallbackTask?.cancel() }
        .onDisappear { fallbackTask?.cancel(); runtime.stop() }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity)
        #endif
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button("Chat history", systemImage: "clock.arrow.circlepath") { focused = false; showHistory = true }.labelStyle(.iconOnly)
            Spacer()
            Menu {
                Button("New chat", systemImage: "square.and.pencil") { focused = false; fallbackTask?.cancel(); Task { await runtime.newChat(context: currentContext) } }
                Button("Use current screen", systemImage: "viewfinder") { runtime.useContext(currentContext) }
                    .disabled(isGenerating || runtime.scope == currentContext)
                ShareLink("Export chat", item: runtime.transcript)
            } label: {
                Text(runtime.chat.activeSession?.title ?? "New Chat").font(.headline).lineLimit(1)
                    .frame(maxWidth: 240)
            }
                .accessibilityLabel("Chat actions")
            Spacer()
            Button("Close", systemImage: "xmark") { fallbackTask?.cancel(); close() }.labelStyle(.iconOnly).accessibilityIdentifier("assistant.close")
        }
        .buttonStyle(.glass).padding(16)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Suggestions").font(.headline)
            if !isReady { Text(runtime.provider.availability.detail).font(.callout).foregroundStyle(.secondary) }
            if !focused && runtime.chat.inputText.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    suggestion("Plan today's study", icon: "calendar", prompt: "Read my study overview and help plan today's study.", fallbackAction: .studyPlan)
                    suggestion("Explore my collection", icon: "books.vertical", prompt: "Show my decks and suggest how to explore this collection.", fallbackAction: .askCollection)
                    if currentContext.noteID != nil || currentContext.title == "Review" {
                        suggestion("Explain this card", icon: "lightbulb", prompt: "Explain the current review card using its note fields.", fallbackAction: .explainCard)
                    }
                }
                .transition(.opacity)
            }
            Label(runtime.provider.privacyDescription, systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: focused)
    }
    private func suggestion(_ title: String, icon: String, prompt: String, fallbackAction: AssistantSuggestion) -> some View {
        Button { focused = false; if isReady { runtime.send(prompt) } else {
            fallbackTask = Task {
                await runtime.fallbackTurn {
                    let count = fallback.messages.count
                    await fallback.perform(fallbackAction)
                    return Array(fallback.messages.dropFirst(count))
                }
                guard !Task.isCancelled else { return }
                if fallbackAction.action == .askCollection { focused = true }
            }
        } } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(isGenerating || (isReady && !runtime.chat.isModelLoaded))
    }
    private var composer: some View {
        @Bindable var chat = runtime.chat
        return VStack(alignment: .leading, spacing: 12) {
            Text(runtime.scope.title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask AI", text: $chat.inputText, axis: .vertical)
                    .accessibilityIdentifier("assistant.composer").textFieldStyle(.plain).lineLimit(1...7).focused($focused).submitLabel(.send)
                    .onSubmit { send() }
                Button {
                    if isGenerating { runtime.stop(); fallbackTask?.cancel() } else { send() }
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
                }.buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(!isGenerating && (runtime.chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isReady && !runtime.chat.isModelLoaded)))
                    .accessibilityLabel(isGenerating ? "Stop" : "Send")
            }
        }.padding(16).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 16).padding(.bottom, 12)
    }
    private func send() {
        focused = false
        if isReady { runtime.send() } else {
            fallback.draft = runtime.chat.inputText
            fallbackTask = Task {
                await runtime.fallbackTurn {
                    let count = fallback.messages.count
                    await fallback.sendDraft()
                    return Array(fallback.messages.dropFirst(count))
                }
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
}

/// Use Manifold's public styling hook; conversation data and provider-facing
/// tool names stay intact while the app shows readable operation status.
private struct AssistantToolStatusStyle: ToolInvocationStyle {
    func makeBody(configuration: Configuration) -> some View {
        let action = configuration.arguments.flatMap { try? JSONDecoder().decode(AssistantToolArguments.self, from: Data($0.utf8)).action }
        let names = ["list_decks": "Read decks", "decks": "Read decks", "list_notetypes": "Read note types", "notetypes": "Read note types", "get_notetype": "Read note fields", "notetype": "Read note fields", "get_study_overview": "Read study overview", "study_overview": "Read study overview", "retrieve": "Search your library", "search_notes": "Find notes", "get_note": "Read note", "get_card": "Read card", "add_note": "Create note", "edit_note": "Edit note", "delete_notes": "Delete notes", "set_tags": "Update tags", "create_deck": "Create deck", "rename_deck": "Rename deck", "update_template": "Update template", "undo": "Undo", "redo": "Redo"]
        let title = action.flatMap { names[$0] } ?? (configuration.toolName == "open_app" ? "Open app surface" : configuration.toolName == "read_collection" ? "Read collection" : "Update collection")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if configuration.state == .running { ProgressView().controlSize(.mini) }
                else { Image(systemName: configuration.state == .completed ? "checkmark.circle" : configuration.state == .awaitingApproval ? "hand.raised" : "minus.circle") }
                Text(LocalizedStringKey(title))
                if configuration.state == .awaitingApproval { Text("Awaiting review").foregroundStyle(.secondary) }
                if configuration.state == .failed { Text("Not completed").foregroundStyle(.secondary) }
            }
            if configuration.state == .failed, let error = configuration.errorPresentation {
                Text(error.summary).foregroundStyle(.secondary)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct AssistantHistory: View {
    let runtime: AssistantRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var renameID: UUID?
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List(runtime.history.displayedSessions) { session in
                Button { Task { await runtime.select(session); dismiss() } } label: {
                    Label(session.title, systemImage: "bubble.left").foregroundStyle(.primary)
                }.contextMenu {
                    Button("Rename") { renameID = session.id; name = session.title }
                    Button("Delete", role: .destructive) { Task { await runtime.delete(session) } }
                }
            }
            .navigationTitle("Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename chat", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
                TextField("Title", text: $name)
                Button("Save") { if let session = runtime.history.displayedSessions.first(where: { $0.id == renameID }) { Task { await runtime.rename(session, title: name) } }; renameID = nil }
                Button("Cancel", role: .cancel) { renameID = nil }
            }
        }.presentationDetents([.medium, .large])
    }
}

private struct AssistantChangeReview: View {
    @Bindable var host: AssistantToolHost
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(host.pendingConsequence) }
                ForEach($host.pendingItems) { $item in
                    Section(item.title) {
                        Toggle("Include", isOn: $item.selected)
                        if !item.before.isEmpty { Text(item.before).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if host.canEditDraft { TextField("Proposed value", text: $item.after, axis: .vertical).lineLimit(1...12) }
                        else { Text(item.after).textSelection(.enabled) }
                    }
                }
            }
            .navigationTitle(host.pendingTitle ?? "Review changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { host.resolve(approve: false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { host.resolve(approve: true) }.disabled(!host.pendingItems.contains(where: \.selected)) }
            }
        }.presentationDetents([.large])
    }
}
