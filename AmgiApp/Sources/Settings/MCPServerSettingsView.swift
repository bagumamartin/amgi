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

    var body: some View {
        form
            .navigationTitle("Agents")
    }

    private var form: some View {
        Form {
            accessSection
            profileSection
            setupSection
            httpSection
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

    // MARK: Web address for HTTP-only apps

    private var httpSection: some View {
        Section {
            if manager.settings.enabled,
               let endpoint = manager.localHTTPEndpoint {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If your assistant asks for a URL instead of a command, use this:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent("Type") {
                        Text("Streamable HTTP")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    LabeledContent("URL") {
                        Text(endpoint.url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button(copiedLabel == "url" ? "Copied" : "Copy") {
                            copy(endpoint.url, label: "url")
                        }
                        .buttonStyle(.borderless)
                    }
                    LabeledContent("Bearer token") {
                        Text(endpoint.token)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Button(copiedLabel == "token" ? "Copied" : "Copy") {
                            copy(endpoint.token, label: "token")
                        }
                        .buttonStyle(.borderless)
                    }
                    Text("Paste Bearer token into the client's “Bearer token” or “Authorization” header field. If it only has Headers, add Key: Authorization, Value: Bearer <token>.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let json = manager.localHTTPJSON() {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Or paste this JSON where your client shows “JSON Configuration”")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(copiedLabel == "httpjson" ? "Copied" : "Copy") {
                                copy(json, label: "httpjson")
                            }
                        }
                        Text(json)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.12)))
                    }
                }
            } else if manager.settings.enabled {
                LabeledContent("Web address") {
                    Text("Starts automatically once you open Amgi")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Web address")
        } footer: {
            Text("For assistants that only offer URL-based setup (SSE / Streamable HTTP). Choose Streamable HTTP where offered. Requires Amgi to stay open — command-based setups above work even if you force-quit Amgi.")
        }
    }

    // MARK: Setup instructions

    /// The stable, user-facing command for a Release install.
    /// DEBUG builds live in DerivedData, but instructions must show the
    /// path users will actually have after dragging Amgi to /Applications.
    private var canonicalHelperPath: String {
        "/Applications/AmgiApp.app/Contents/Helpers/amgi-mcp"
    }

    /// Step-by-step, copy-paste-ready setup per client. Written for
    /// non-technical users: where to click, what to paste, and the one
    /// restart that makes it take effect.
    private var setupSection: some View {
        Section {
            if manager.detectedHelperPath != nil {
                // The one value every form-based client asks for — always
                // show the Release location, not the ephemeral DerivedData
                // path that appears when running from Xcode.
                let displayPath = canonicalHelperPath
                HStack {
                    VStack(alignment: .leading) {
                        Text("Command")
                        Text(displayPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(copiedLabel == "path" ? "Copied" : "Copy") {
                        copy(displayPath, label: "path")
                    }
                }
                ForEach(MCPManager.MCPClient.allCases) { client in
                    DisclosureGroup {
                        clientSetup(client: client, helperPath: displayPath)
                    } label: {
                        Label(client.rawValue, systemImage: client.iconName)
                    }
                }
            } else {
                Text("This copy of Amgi is missing part of the assistant feature. Updating or reinstalling Amgi restores it.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connect an AI assistant")
        } footer: {
            Text("Whichever assistant you connect follows the rules you set above. It works whether Amgi is open or not — agents keep going even if you force-quit this app. Changes made by assistants stay in your collection and sync to your other devices as usual.")
        }
    }

    @ViewBuilder
    private func clientSetup(client: MCPManager.MCPClient, helperPath: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(client.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(step)
                        .font(.callout)
                }
            }

            ForEach(manager.connectionSnippets(for: client, helperPath: helperPath)) { snippet in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(snippet.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
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
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }
        }
        .padding(.vertical, 4)
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
