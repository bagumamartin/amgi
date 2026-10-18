import AmgiAppCore
import AmgiTheme
import AmgiUI
import SwiftUI

/// Connected AI providers: ChatGPT (sign-in or API key) and Claude (API
/// key). One panel, used by Settings and by the chat's model menu.
struct AssistantConnectionsPanel: View {
    @Environment(\.palette) private var palette
    @State private var sheet: Sheet?
    private var store: AssistantProviderStore { .shared }

    enum Sheet: String, Identifiable {
        case openAI, anthropic
        var id: String { rawValue }
    }

    @AppStorage(AutomationPreferences.foundationModelsEnabledKey) private var appleEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            appleRow
            Divider().padding(.leading, 72)
            openAIRow
            Divider().padding(.leading, 72)
            anthropicRow
        }
        .modifier(ChatGPTPlanWelcome(store: .shared))
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .openAI: ConnectOpenAISheet()
            case .anthropic: APIKeySheet(provider: .anthropic)
            }
        }
    }

    private var appleRow: some View {
        let availability = FoundationModelService.availability
        return ConnectionRow(
            provider: .apple, title: L10n.text("Apple Intelligence"),
            status: availability == .ready ? L10n.text("Private, on this device") : availability.detail,
            busy: false, error: nil
        ) {
            Toggle("Use Apple Intelligence", isOn: $appleEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(palette.accent)
        }
    }

    private var openAIRow: some View {
        let chatGPT = store.isConnected(.chatGPT)
        let key = store.isConnected(.openAI)
        let status: String = switch (chatGPT, key) {
        case (true, true): L10n.text("ChatGPT plan and API key")
        case (true, false): store.chatGPTEmail ?? L10n.text("Using your ChatGPT plan")
        case (false, true): L10n.text("Connected with an API key")
        case (false, false): L10n.text("ChatGPT plan or API key")
        }
        return ConnectionRow(
            provider: .chatGPT, title: "OpenAI",
            status: status,
            busy: store.loading.contains(.chatGPT) || store.loading.contains(.openAI),
            error: store.lastError[.chatGPT] ?? store.lastError[.openAI]
        ) {
            if chatGPT || key {
                Menu {
                    if chatGPT {
                        Button("Sign Out of ChatGPT", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task { await store.disconnect(.chatGPT) }
                        }
                    } else {
                        Button("Continue with ChatGPT", systemImage: "person.crop.circle") { Task { await store.signInWithChatGPT() } }
                    }
                    if key {
                        Button("Remove API Key", systemImage: "key.slash", role: .destructive) { Task { await store.disconnect(.openAI) } }
                    } else {
                        Button("Add API Key…", systemImage: "key") { sheet = .openAI }
                    }
                } label: {
                    ConnectionButtonLabel(title: L10n.text("Manage"), prominent: false)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            } else {
                Button { sheet = .openAI } label: { ConnectionButtonLabel(title: L10n.text("Connect"), prominent: true) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var anthropicRow: some View {
        let connected = store.isConnected(.anthropic)
        return ConnectionRow(
            provider: .anthropic, title: "Claude",
            status: connected ? L10n.text("Connected with an API key") : L10n.text("Anthropic API key"),
            busy: store.loading.contains(.anthropic), error: store.lastError[.anthropic]
        ) {
            if connected {
                Button { Task { await store.disconnect(.anthropic) } } label: {
                    ConnectionButtonLabel(title: L10n.text("Remove"), prominent: false)
                }
                .buttonStyle(.plain)
            } else {
                Button { sheet = .anthropic } label: { ConnectionButtonLabel(title: L10n.text("Connect"), prominent: true) }
                    .buttonStyle(.plain)
            }
        }
    }
}

private struct ConnectionRow<Trailing: View>: View {
    let provider: AssistantProvider
    let title: String
    let status: String
    let busy: Bool
    let error: String?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            HStack(spacing: AmgiSpacing.lg) {
                ProviderMark(provider: provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).amgiFont(.bodyEmphasis).foregroundStyle(palette.textPrimary).lineLimit(1)
                    Text(status).amgiFont(.caption).foregroundStyle(palette.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: AmgiSpacing.sm)
                if busy { ProgressView().controlSize(.small) } else { trailing().fixedSize() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 56)
            }
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.vertical, AmgiSpacing.md)
    }
}

private struct ConnectionButtonLabel: View {
    let title: String
    let prominent: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Text(title)
            .amgiFont(.captionBold)
            .foregroundStyle(prominent ? palette.background : palette.textPrimary)
            .padding(.horizontal, AmgiSpacing.md)
            .frame(height: 32)
            .background(prominent ? palette.textPrimary : palette.background, in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Connect to OpenAI

/// Craft-style chooser: sign in with ChatGPT (primary), or paste a key.
private struct ConnectOpenAISheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var usesKey = false
    private var store: AssistantProviderStore { .shared }

    var body: some View {
        NavigationStack {
            if usesKey {
                APIKeyForm(provider: .openAI) { dismiss() }
            } else {
                VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                    Text("Use your ChatGPT plan, or an OpenAI Platform API key billed to your OpenAI account. Messages go straight from this device to OpenAI; Ijuka runs no server in between, and charges nothing for this.")
                        .amgiFont(.body)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = store.lastError[.chatGPT] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.warning)
                    }
                    Spacer(minLength: 0)
                    ContinueWithChatGPTButton(isLoading: store.loading.contains(.chatGPT)) {
                        Task {
                            await store.signInWithChatGPT()
                            if store.isConnected(.chatGPT) { dismiss() }
                        }
                    }
                    // OpenAI only accepts a plain-HTTP loopback redirect, which
                    // Safari's optional "Not Secure Connection Warning" stops on.
                    Label("If Safari warns that 127.0.0.1 isn't secure, that address is Ijuka on this device receiving your sign-in. Choose Visit Website to finish.", systemImage: "info.circle")
                        .amgiFont(.micro)
                        .foregroundStyle(palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { usesKey = true } label: {
                        Text("Use an OpenAI API Key")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 45)
                            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous).strokeBorder(palette.separator, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
                .padding(AmgiSpacing.xl)
                .navigationTitle("Connect to OpenAI")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

private struct APIKeySheet: View {
    let provider: AssistantProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack { APIKeyForm(provider: provider) { dismiss() } }
            .presentationDetents([.medium])
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 300)
            #endif
    }
}

private struct APIKeyForm: View {
    let provider: AssistantProvider
    let done: () -> Void
    @Environment(\.palette) private var palette
    @State private var key = ""
    @FocusState private var focused: Bool
    private var store: AssistantProviderStore { .shared }

    private var keysURL: URL {
        provider == .anthropic
            ? URL(string: "https://console.anthropic.com/settings/keys")!
            : URL(string: "https://platform.openai.com/api-keys")!
    }

    var body: some View {
        Form {
            Section {
                SecureField(provider == .anthropic ? "sk-ant-…" : "sk-…", text: $key)
                    .focused($focused)
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(save)
            } footer: {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    if let error = store.lastError[provider] {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(palette.warning)
                    }
                    Text("Stored in this device's keychain and sent only to \(provider == .anthropic ? "Anthropic" : "OpenAI"). Usage is billed to your account.")
                    Link("Create a key", destination: keysURL)
                }
            }
        }
        .navigationTitle(provider == .anthropic ? "Anthropic API Key" : "OpenAI API Key")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            ToolbarItem(placement: .confirmationAction) {
                if store.loading.contains(provider) {
                    ProgressView()
                } else {
                    Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        Task { if await store.connect(provider, apiKey: key) { done() } }
    }
}

// MARK: - From the chat

/// The connections panel as a sheet, opened from the chat's model menu.
struct AssistantConnectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                    Text("Connect your own account to use stronger models and to attach photos and PDFs. Apple Intelligence stays available, on this device.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, AmgiSpacing.xs)
                    AssistantConnectionsPanel()
                        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous).strokeBorder(palette.separator, lineWidth: 0.5)
                        }
                }
                .padding(AmgiSpacing.lg)
            }
            .background(palette.surface)
            .navigationTitle("AI Connections")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}
