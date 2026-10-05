import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import Sharing
import WidgetKit

struct AppearanceSettingsView: View {
    @Bindable var manager: ThemeManager
    @Shared(.appStorage(AppearancePreferences.Keys.appFont))
    private var appFontRaw: String = AppFont.system.rawValue
    /// The app language, bound straight to the observable store. Binding
    /// through `overrideTag` — rather than a local `@State` copy mirrored by
    /// an `onChange` — is what makes the write land in one place: the store
    /// owns both the App Group persistence and the observation that
    /// re-renders the app, and a local mirror could only ever get one right.
    @Bindable private var appLocale = AppLocaleModel.shared
    @State private var engineRelaunchNeeded = false

    /// `""` is the "System" row, which clears the override.
    private var languageTag: Binding<String> {
        Binding(
            get: { appLocale.overrideTag ?? "" },
            set: { newValue in
                let previous = appLocale.overrideTag
                appLocale.setOverride(newValue)
                // The engine's `preferred_langs` was fixed when the backend was
                // constructed, and rebuilding it here would drop the open
                // collection's lock mid-session — so say so rather than
                // pretending it applied.
                engineRelaunchNeeded = previous != appLocale.overrideTag
            }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsSectionHeader(title: "Theme")
            themePickerRow

            SettingsSectionHeader(title: "Appearance")
            SettingsGroup {
                Picker("Appearance", selection: $manager.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
                .padding(AmgiSpacing.md)
            }
            languageRow

            SettingsSectionHeader(title: "App Font")
            SettingsGroup {
                SettingsPickerRow(
                    title: "Font",
                    systemImage: "textformat",
                    tone: .accent,
                    selection: Binding($appFontRaw)
                ) {
                    Text("System").tag(AppFont.system.rawValue)
                    Text("Serif").tag(AppFont.serif.rawValue)
                }
            }
            SettingsFootnote("Changes the font used throughout the app. Card-template content and hero numbers stay in their own typeface.")

            SettingsSectionHeader(title: "Preview")
            PreviewCard()
                .padding(.horizontal, AmgiSpacing.lg)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: manager.themeID) { _, _ in reloadWidget() }
        .onChange(of: manager.appearance) { _, _ in reloadWidget() }
        .onChange(of: appLocale.overrideTag) { _, _ in reloadWidgetForLanguageChange() }
    }

    // MARK: - Language

    private var languageRow: some View {
        Group {
            SettingsSectionHeader(title: "Language")
            SettingsGroup {
                SettingsPickerRow(
                    title: "App Language",
                    systemImage: "globe",
                    tone: .info,
                    selection: languageTag
                ) {
                    Text("System").tag("")
                    ForEach(AppLocale.availableLanguageTags, id: \.self) { tag in
                        Text(verbatim: AppLocale.languageName(for: tag)).tag(tag)
                    }
                }
            }
            if engineRelaunchNeeded {
                SettingsFootnote("Relaunch Ijuka to apply this language to text that comes from the Anki engine, such as card errors and undo names.")
            } else {
                SettingsFootnote("System follows your device language. Changing this also changes the language the Anki engine uses.")
            }
        }
    }

    /// The picker writes through `languageTag`; this only refreshes the widget
    /// timeline, whose strings come from this same locale.
    private func reloadWidgetForLanguageChange() {
        reloadWidget()
    }

    /// Theme cards draw their own selected/unselected frame, so they sit
    /// directly on the page — nesting them in a `SettingsGroup` would put a
    /// second border around every card.
    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: "AmgiWidget")
    }

    @ViewBuilder
    private var themePickerRow: some View {
        let themes = ThemeRegistry.shared.allThemes()
        #if os(macOS)
        // Wide layouts get a compact adaptive grid instead of full-width
        // stacked cards.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: AmgiSpacing.md)], spacing: AmgiSpacing.md) {
            themeCards(themes)
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.vertical, AmgiSpacing.xs)
        #else
        VStack(spacing: AmgiSpacing.md) {
            themeCards(themes)
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.vertical, AmgiSpacing.xs)
        #endif
    }

    @ViewBuilder
    private func themeCards(_ themes: [PaletteData]) -> some View {
        ForEach(themes, id: \.id) { data in
            let id = ThemeID(rawValue: data.id)
            ThemeCard(
                themeID: id,
                label: data.displayName,
                isSelected: manager.themeID == id
            ) {
                manager.themeID = id
            }
        }
    }
}

private struct ThemeCard: View {
    let themeID: ThemeID
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let preview = ThemeRegistry.shared.palette(id: themeID, scheme: systemScheme)
        Button(action: onTap) {
            HStack(spacing: AmgiSpacing.md) {
                VStack(spacing: 4) {
                    bar(color: preview.background)
                    bar(color: preview.surface)
                    bar(color: preview.accent)
                }
                .padding(AmgiSpacing.sm)
                .background(preview.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.small))
                .frame(width: 80)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(LocalizedStringKey(label)).bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AmgiSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AmgiRadius.inset)
                    .stroke(isSelected ? preview.accent : preview.border, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.pressScale)
    }
}

private extension ThemeCard {
    func bar(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color).frame(height: 10)
    }
}

private struct PreviewCard: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text("Preview")
                .amgiFont(.cardTitle)
                .foregroundStyle(palette.textPrimary)
            Text("Body text in the active palette.")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)

            HStack(spacing: AmgiSpacing.sm) {
                badge("Positive", color: palette.positive)
                badge("Warning", color: palette.warning)
                badge("Danger", color: palette.danger)
            }

            Button("Primary action") {}
                .buttonStyle(AmgiPrimaryButtonStyle())
        }
        .padding(AmgiSpacing.lg)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
    }
}

private extension PreviewCard {
    func badge(_ text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text))
            .amgiFont(.captionBold)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}

#if DEBUG

#Preview("Vivid Light") {
    NavigationStack { AppearanceSettingsView(manager: ThemeManager(defaults: UserDefaults(suiteName: "preview-vivid-light")!)) }
        .environment(\.palette, ThemeRegistry.shared.palette(id: .vivid, scheme: .light))
        .preferredColorScheme(.light)
}

#Preview("Muted Dark") {
    NavigationStack { AppearanceSettingsView(manager: ThemeManager(defaults: UserDefaults(suiteName: "preview-muted-dark")!)) }
        .environment(\.palette, ThemeRegistry.shared.palette(id: .muted, scheme: .dark))
        .preferredColorScheme(.dark)
}
#endif
