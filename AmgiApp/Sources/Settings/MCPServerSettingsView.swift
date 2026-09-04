import AmgiTheme
import AnkiKit
import SwiftUI

/// Agent access settings — deliberately free of implementation
/// vocabulary. From the user's point of view there is no "helper",
/// "server", or "binary": installing Amgi is the entire setup, and this
/// pane only answers three questions: who may connect, how much they
/// may do, and how to point an assistant at Amgi.
#if os(macOS)
struct MCPServerSettingsView: View {
    @State private var manager = MCPManager.shared
    @State private var copiedLabel: String?
    @Environment(\.palette) private var palette

    var body: some View {
        form
            .navigationTitle("Agents")
    }

    private var form: some View {
        Form {
            accessSection
            profileSection
            setupSection
        }
    }

    // MARK: Access & safety

    private var accessSection: some View {
        Section {
            Toggle("Let AI assistants work with Amgi", isOn: enabledBinding)
            if manager.settings.enabled {
                Picker("They can…", selection: tierBinding) {
                    Text("Only look").tag(ToolTier.readOnly)
                    Text("Look and add notes").tag(ToolTier.safeWrite)
                    Text("Do everything, including delete").tag(ToolTier.full)
                }
                .pickerStyle(.radioGroup)

                Toggle("Allow changes while Amgi is open", isOn: blockBinding)
                Toggle("Keep an automatic backup before any deletion", isOn: snapshotsBinding)
            }
        } header: {
            Text("Agent Access")
        } footer: {
            Text(accessFooter)
        }
    }

    private var accessFooter: String {
        guard manager.settings.enabled else {
            return "While off, assistants cannot connect at all."
        }
        switch manager.settings.tier {
        case .readOnly:
            return "Assistants can browse decks, search notes, render cards, and read stats — nothing is ever changed."
        case .safeWrite:
            return "Assistants can create and edit notes, manage tags, decks, media, and settings. Deletions stay locked."
        case .full:
            return "Assistants can also delete notes and decks. A backup is taken first when enabled above."
        }
    }

    // MARK: Profile exposure

    private var profileSection: some View {
        Section("Which collection to share") {
            Picker("Collection", selection: profileBinding) {
                Text("The one you're using").tag(String?.none)
                ForEach(AccountStore.shared.accounts) { account in
                    Text(account.displayName).tag(String?.some(account.id))
                }
            }
        }
    }

    // MARK: Setup instructions

    /// The single industry-standard registration. Every MCP client
    /// speaks stdio + `uvx` — no per-client formats, no absolute paths.
    private var setupSection: some View {
        Section {
            if manager.detectedHelperPath != nil {
                ForEach(manager.connectionSnippets) { snippet in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(snippet.label)
                                .amgiFont(.captionBold)
                                .foregroundStyle(palette.textSecondary)
                            Spacer()
                            Button(copiedLabel == snippet.id ? "Copied" : "Copy") {
                                copy(snippet.text, label: snippet.id)
                            }
                        }
                        Text(snippet.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: AmgiRadius.small)
                                    .fill(palette.textSecondary.opacity(0.12))
                            )
                    }
                }
            } else {
                Text("This copy of Amgi is missing part of the assistant feature. Updating or reinstalling Amgi restores it.")
                    .foregroundStyle(palette.textSecondary)
            }
        } header: {
            Text("Connect an AI assistant")
        } footer: {
            Text("Works with any MCP client (Claude, Cursor, Codex, Zed, Gemini, Qwen, …): choose STDIO, Command uvx, Parameters amgi-mcp — or paste the JSON. First launch downloads the tiny launcher from PyPI. If your client shows an error, run uvx amgi-mcp --help once in Terminal to warm the cache, then restart the client. Works whether Amgi is open or not.")
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLabel = label
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedLabel = nil
        }
    }

    // MARK: Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { manager.settings.enabled },
            set: { newValue in manager.update { $0.enabled = newValue } }
        )
    }
    private var tierBinding: Binding<ToolTier> {
        Binding(
            get: { manager.settings.tier },
            set: { newValue in manager.update { $0.tier = newValue } }
        )
    }
    private var blockBinding: Binding<Bool> {
        Binding(
            get: { manager.settings.blockWritesWhileAppRunning },
            set: { newValue in manager.update { $0.blockWritesWhileAppRunning = newValue } }
        )
    }
    private var snapshotsBinding: Binding<Bool> {
        Binding(
            get: { manager.settings.snapshotsBeforeDestructive },
            set: { newValue in manager.update { $0.snapshotsBeforeDestructive = newValue } }
        )
    }
    private var profileBinding: Binding<String?> {
        Binding(
            get: { manager.settings.profileID },
            set: { newValue in manager.update { $0.profileID = newValue } }
        )
    }
}
#else
struct MCPServerSettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "Mac Only",
            systemImage: "desktopcomputer",
            description: Text("AI assistants connect through Amgi for Mac.")
        )
    }
}
#endif

#if DEBUG
#Preview {
    NavigationStack {
        MCPServerSettingsView()
    }
}
#endif
