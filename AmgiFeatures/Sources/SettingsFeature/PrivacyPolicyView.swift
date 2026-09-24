import SwiftUI
import AmgiUI
import AmgiTheme

struct PrivacyPolicyView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsPage {
            SettingsSectionHeader(title: "Overview")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                    Text("Ijuka is built with a strict local-first and privacy-respecting philosophy. We do not track you, sell your data, or serve advertisements.")
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                }
                .padding(.horizontal, AmgiSpacing.lg)
                .padding(.vertical, AmgiSpacing.md)
            }

            SettingsSectionHeader(title: "Data Storage & Sync")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Label("On-Device Storage", systemImage: "internaldrive")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("All flashcards, review histories, notes, and imported books stay strictly stored in your local application container on your device.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)

                    Divider().padding(.vertical, AmgiSpacing.xs)

                    Label("Custom Sync Servers", systemImage: "server.rack")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("If you configure sync, communication occurs directly between your device and your specified sync server over encrypted HTTPS. Ijuka operates no intermediary servers.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, AmgiSpacing.lg)
                .padding(.vertical, AmgiSpacing.md)
            }

            SettingsSectionHeader(title: "Apple Intelligence & System Search")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Label("On-device Assistance", systemImage: "sparkles")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("When enabled and available, Study Assistant sends a bounded set of matching note fields to Apple’s on-device system model. Ijuka does not proxy these requests through an Ijuka server. The assistant cannot rate, schedule, edit, or delete cards in this release.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, AmgiSpacing.xs)

                    Label("System Search", systemImage: "magnifyingglass")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("Deck names can be indexed in Spotlight so system search can open Ijuka. Note answers are not indexed. Showing private note titles in system results is off unless you enable it in Settings.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AmgiSpacing.lg)
            }

            SettingsSectionHeader(title: "Permissions")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Label("Microphone & Camera", systemImage: "mic.and.signal.meter")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("Used solely when you explicitly capture photos or record audio notes directly to attach to your cards. No background recording or telemetry occurs.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)

                    Divider().padding(.vertical, AmgiSpacing.xs)

                    Label("Photo Library", systemImage: "photo")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("Used only when you choose to insert an existing image or media file into a flashcard.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, AmgiSpacing.lg)
                .padding(.vertical, AmgiSpacing.md)
            }

            SettingsSectionHeader(title: "Analytics & Tracking")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Label("Zero Tracking", systemImage: "hand.raised.fill")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                    Text("Ijuka includes no third-party tracking SDKs, analytics engines, or advertising networks. We do not collect or share personal identifiers.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, AmgiSpacing.lg)
                .padding(.vertical, AmgiSpacing.md)
            }

            SettingsFootnote("Last updated: September 2026. For questions regarding privacy, please consult the project repository documentation.")
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
#endif
