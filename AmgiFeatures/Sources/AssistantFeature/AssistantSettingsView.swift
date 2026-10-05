public import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AmgiUI

public struct AssistantSettingsView: View {
    @Environment(\.palette) private var palette

    @AppStorage(AutomationPreferences.foundationModelsEnabledKey)
    private var foundationModelsEnabled = true
    @AppStorage(AutomationPreferences.exposeNoteTitlesKey)
    private var exposeNoteTitles = false
    @AppStorage(AutomationPreferences.spotlightDeckNamesKey)
    private var spotlightDeckNames = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
                statusPanel
                generationPanel
                systemSearchPanel
                privacyPanel
            }
            .padding(.horizontal, AmgiSpacing.xl)
            .padding(.vertical, AmgiSpacing.xl)
        }
        .amgiScreenCanvas()
        .navigationTitle("Apple Intelligence")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var statusPanel: some View {
        AssistantSettingsPanel {
            HStack(spacing: AmgiSpacing.md) {
                AssistantSettingsIcon(
                    systemImage: "sparkles",
                    color: FoundationModelService.availability == .ready ? palette.positive : palette.warning
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("System model")
                        .amgiFont(.bodyEmphasis)
                    Text(FoundationModelService.availability.detail)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
            }
            .padding(AmgiSpacing.lg)
        }
    }

    private var generationPanel: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            AssistantSettingsHeader("Generation")
            AssistantSettingsPanel {
                Toggle(isOn: $foundationModelsEnabled) {
                    AssistantSettingsLabel(
                        title: "Use Apple Intelligence",
                        subtitle: "Uses Apple's on-device model when available. Turning it off keeps deterministic study summaries."
                    )
                }
                .tint(palette.accent)
                .padding(AmgiSpacing.lg)
            }
        }
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
                    Text("Study Assistant sends only a bounded set of matching note fields to Apple's system model. Ijuka does not proxy those requests through its own server, and the assistant cannot rate, schedule, edit, or delete cards.")
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
