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
                    Text("Amgi is built with a strict local-first and privacy-respecting philosophy. We do not track you, sell your data, or serve advertisements.")
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
                    Text("If you configure sync, communication occurs directly between your device and your specified sync server over encrypted HTTPS. Amgi operates no intermediary servers.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, AmgiSpacing.lg)
                .padding(.vertical, AmgiSpacing.md)
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
                    Text("Amgi includes no third-party tracking SDKs, analytics engines, or advertising networks. We do not collect or share personal identifiers.")
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
