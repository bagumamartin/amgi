public import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AmgiEmbeddings
import AmgiTheme
import AmgiUI

public struct AssistantSettingsView: View {
    @Environment(\.palette) private var palette

    @AppStorage(AutomationPreferences.exposeNoteTitlesKey)
    private var exposeNoteTitles = false
    @AppStorage(AutomationPreferences.spotlightDeckNamesKey)
    private var spotlightDeckNames = true

    public init() {}

    /// The default model's name, for the Settings row.
    @MainActor public static var modelSummary: String {
        let model = AssistantProviderStore.shared.effectiveModel
        return model.provider == .apple ? FoundationModelService.availability.title : model.name
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
                modelsPanel
                retrievalPanel
                systemSearchPanel
                privacyPanel
            }
            .padding(.horizontal, AmgiSpacing.xl)
            .padding(.vertical, AmgiSpacing.xl)
        }
        .amgiScreenCanvas()
        .navigationTitle("AI Assistant")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var retrievalPanel: some View {
        let retrieval = CollectionRetrievalCoordinator.shared
        return VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            AssistantSettingsHeader("Collection retrieval")
            AssistantSettingsPanel {
                VStack(alignment: .leading, spacing: 16) {
                    ModelAssetStatusView()
                    Divider()
                    if retrieval.isIndexing {
                        ProgressView(value: Double(retrieval.completed), total: Double(max(1, retrieval.total))) {
                            Text("Indexing \(retrieval.completed) of \(retrieval.total) sources")
                        }
                        Button("Pause indexing") { retrieval.pause() }
                    } else {
                        Button("Resume indexing", systemImage: "arrow.clockwise") { retrieval.resume() }
                            .disabled(!ModelAssetManager.isModelInstalled)
                    }
                    Text("Search covers this profile's notes, managed media and reader library. Indexing resumes from verified segments and pauses during low power or high temperature.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !retrieval.failures.isEmpty {
                        DisclosureGroup("\(retrieval.failures.count) sources need attention") {
                            ForEach(Array(retrieval.failures.prefix(50).enumerated()), id: \.offset) { _, message in
                                Text(message).font(.caption).textSelection(.enabled)
                            }
                            Button("Retry indexing") { retrieval.resume() }
                        }
                    }
                }.padding(AmgiSpacing.lg)
            }
        }
    }

    private var modelsPanel: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            AssistantSettingsHeader("Models")
            AssistantSettingsPanel { AssistantConnectionsPanel() }
            Text("Connect your own ChatGPT plan or API key for stronger models and photo and PDF attachments. Requests go straight from this device to the provider.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AmgiSpacing.xs)
            AssistantSettingsPanel { defaultModelRow }
                .padding(.top, AmgiSpacing.sm)
        }
    }

    private var defaultModelRow: some View {
        let store = AssistantProviderStore.shared
        let current = store.effectiveModel
        let connected = AssistantProvider.allCases.filter { $0.isCloud && store.isConnected($0) }
        return HStack(spacing: AmgiSpacing.md) {
            Text("New chats use")
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: AmgiSpacing.sm)
            Menu {
                Button { store.select(.onDevice) } label: {
                    if current == .onDevice { Label(AssistantModel.onDevice.name, systemImage: "checkmark") } else { Text(AssistantModel.onDevice.name) }
                }
                ForEach(connected) { provider in
                    Section(provider.title) {
                        ForEach(store.models[provider] ?? []) { model in
                            Button { store.select(model) } label: {
                                if current == model { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: AmgiSpacing.sm) {
                    ProviderGlyph(provider: current.provider, size: 14)
                        .foregroundStyle(palette.textPrimary)
                    Text(current.name)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .frame(minHeight: 56)
    }

    private var systemSearchPanel: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            AssistantSettingsHeader("System Search")
            AssistantSettingsPanel {
                VStack(spacing: 0) {
                    Toggle(isOn: $spotlightDeckNames) {
                        AssistantSettingsLabel(
                            title: "Deck names in Spotlight",
                            subtitle: "Lets Spotlight and Siri find decks. Note answers are never indexed."
                        )
                    }
                    .tint(palette.accent)
                    .padding(AmgiSpacing.lg)
                    .onChange(of: spotlightDeckNames) { _, _ in
                        Task { try? await SystemSpotlightIndexer.shared.refreshDecks() }
                    }

                    Divider().padding(.leading, 66)

                    Toggle(isOn: $exposeNoteTitles) {
                        AssistantSettingsLabel(
                            title: "Show note titles in system results",
                            subtitle: "When off, Siri reports match counts without placing private note titles in the response."
                        )
                    }
                    .tint(palette.accent)
                    .padding(AmgiSpacing.lg)
                }
            }
        }
    }

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            AssistantSettingsHeader("Privacy")
            AssistantSettingsPanel {
                VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                    Label("On-device by default", systemImage: "iphone.gen3")
                        .amgiFont(.bodyEmphasis)
                    Text("With Apple Intelligence, everything stays on this device. With ChatGPT or Claude, your message, the contexts you attach and any files go directly to that provider under your account — Ijuka runs no server in between. Either way, collection changes require your review before saving.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Profile fenced", systemImage: "person.crop.circle.badge.checkmark")
                        .amgiFont(.bodyEmphasis)
                    Text("If the active profile changes while the assistant is working, the response is discarded instead of being shown in the wrong collection.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AmgiSpacing.lg)
            }
        }
    }
}

private struct AssistantSettingsPanel<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                    .stroke(palette.separator, lineWidth: 0.5)
            }
    }
}

private struct AssistantSettingsHeader: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .amgiFont(.micro)
            .fontWeight(.semibold)
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, AmgiSpacing.xs)
    }
}

private struct AssistantSettingsLabel: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .amgiFont(.body)
            Text(subtitle)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AssistantSettingsIcon: View {
    @Environment(\.palette) private var palette
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }
}
