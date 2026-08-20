import AmgiUI
import SwiftUI
import AmgiTheme
import AmgiAppCore
import AnkiKit
import AnkiClients
import AnkiSync
import Dependencies
import Sharing

// MARK: - Content

/// Pure render surface for the sync sheet — no `@Dependency`, no data
/// loading. Every dynamic value arrives as a `let`; every action is a
/// closure the Container fulfils.
struct SyncSheetContent: View {
    @Environment(\.palette) private var palette

    let state: SyncSheetState
    let endpoint: String?
    let username: String?
    let syncMode: SyncMode
    let isAnkiWeb: Bool
    let logEntries: [SyncLogEntry]
    let lastSyncedLabel: String
    let footerError: String?
    let onDone: () -> Void
    let onChangeServer: () -> Void
    let onLogout: () -> Void
    let onSetUpServer: () -> Void
    let onRetryFooter: () -> Void
    let onStartSync: () -> Void
    let onFullSync: (SyncDirection) -> Void
    let onMerge: () -> Void

    /// Direction awaiting the user's "this cannot be undone" confirmation.
    @State private var pendingDestructiveChoice: SyncDirection?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                serverConfigSection
                    .padding(.top)

                if isAnkiWeb {
                    AnkiMobileAttributionView()
                        .padding(.horizontal)
                }

                Spacer()
                stateView
                Spacer()

                syncLogPanel
                    .padding(.horizontal)
                statusFooter
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .idle:
            ProgressView("Preparing sync...")
        case .syncing(let message):
            ProgressView(message)
        case .success(let summary):
            successView(summary)
        case .error(let message):
            errorView(message)
        case .needsFullSync:
            fullSyncChoiceView
        case .noServer:
            noServerView
        }
    }

    @ViewBuilder
    private var serverConfigSection: some View {
        VStack(spacing: 8) {
            if let endpoint {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                        Text(endpoint)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let username {
                            Text(username)
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("Change Server") { onChangeServer() }
                        Button("Logout", role: .destructive) { onLogout() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .padding(.horizontal)
            } else if syncMode == .local {
                HStack {
                    Label("Syncing is disabled", systemImage: "iphone")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Set Up Server") { onSetUpServer() }
                        .amgiFont(.caption)
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var noServerView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(palette.textSecondary)
            Text("No Server Configured")
                .amgiFont(.sectionHeading)
            Text("Set up a sync server to keep your collection in sync across devices.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Set Up Server") { onSetUpServer() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var syncLogPanel: some View {
        if !logEntries.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(logEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .amgiFont(.micro, .monospaced)
                                    .foregroundStyle(palette.textSecondary)
                                Text(entry.message)
                                    .amgiFont(.caption)
                                    .foregroundStyle(color(for: entry.level))
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .background(palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small))
                .onChange(of: logEntries.count) { _, _ in
                    if let last = logEntries.last {
                        withAnimation(AmgiMotion.standard) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lastSyncedLabel)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)

            if let footerError {
                HStack {
                    Text(footerError)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { onRetryFooter() }
                        .amgiFont(.captionBold)
                }
            }
        }
    }

    private var fullSyncChoiceView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(palette.warning)
            Text("Full Sync Required")
                .amgiFont(.sectionHeading)
            Text("Your local and server collections have diverged. Choose how to reconcile them — Merge is the safest option.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button {
                    onMerge()
                } label: {
                    VStack(spacing: 2) {
                        Label("Merge (combine both)", systemImage: "arrow.triangle.merge")
                            .frame(maxWidth: .infinity)
                        Text("Keeps cards from both sides; conflicts use newest")
                            .amgiFont(.micro)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    pendingDestructiveChoice = .download
                } label: {
                    VStack(spacing: 2) {
                        Label("Replace local with server", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                        Text("Local-only changes will be lost")
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    pendingDestructiveChoice = .upload
                } label: {
                    VStack(spacing: 2) {
                        Label("Replace server with local", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                        Text("Server-only changes will be lost")
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .confirmationDialog(
            "This cannot be undone",
            isPresented: Binding(
                get: { pendingDestructiveChoice != nil },
                set: { if !$0 { pendingDestructiveChoice = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDestructiveChoice
        ) { choice in
            Button(destructiveButtonLabel(choice), role: .destructive) {
                onFullSync(choice)
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(destructiveDialogMessage(choice))
        }
    }

    private func destructiveButtonLabel(_ choice: SyncDirection) -> String {
        switch choice {
        case .download: return "Replace Local"
        case .upload: return "Replace Server"
        }
    }

    private func destructiveDialogMessage(_ choice: SyncDirection) -> String {
        switch choice {
        case .download:
            return "Your local collection will be permanently overwritten with the server's copy. Any cards or reviews that exist only locally will be lost."
        case .upload:
            return "The server's collection will be permanently overwritten with your local copy. Any cards or reviews that exist only on the server will be lost."
        }
    }

    @ViewBuilder
    private func successView(_ summary: SyncSummary) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(palette.positive)
            Text("Sync Complete")
                .amgiFont(.sectionHeading)
            VStack(alignment: .leading, spacing: 4) {
                if summary.cardsPulled > 0 { Text("\u{2193} \(summary.cardsPulled) cards received") }
                if summary.cardsPushed > 0 { Text("\u{2191} \(summary.cardsPushed) cards sent") }
                if summary.notesPulled > 0 { Text("\u{2193} \(summary.notesPulled) notes received") }
                if summary.notesPushed > 0 { Text("\u{2191} \(summary.notesPushed) notes sent") }
                if summary.cardsPulled == 0 && summary.cardsPushed == 0 {
                    Text("Everything up to date")
                }
            }
            .amgiFont(.caption)
            .foregroundStyle(palette.textSecondary)
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(palette.warning)
            Text("Sync Failed")
                .amgiFont(.sectionHeading)
            Text(message)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { onStartSync() }
                .buttonStyle(.borderedProminent)
        }
    }

    func color(for level: SyncLogEntry.Level) -> Color {
        switch level {
        case .info: return palette.textPrimary
        case .warning: return palette.warning
        case .error: return palette.danger
        }
    }
}
