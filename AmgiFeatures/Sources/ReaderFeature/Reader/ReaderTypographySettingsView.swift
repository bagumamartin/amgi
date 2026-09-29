import AmgiTheme
import Sharing
import SwiftUI
import AmgiUI

/// Apple Books-style typography sheet. Surfaced from the `Aa` button in
/// `EPUBChapterReaderView`'s top chrome. Edits land in `@Shared(.appStorage)`
/// so the chapter VC's `styleTokens` recomputation fires immediately.
struct ReaderTypographySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @Shared(.appStorage(ReaderTypographyPreferences.Keys.fontFamily))
    private var fontFamilyRaw: String = ReaderTypographyPreferences.FontFamily.system.rawValue
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.fontSize))
    private var fontSize: Int = 17
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.lineHeight))
    private var lineHeight: Double = 1.55
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.pageMargin))
    private var pageMarginRaw: String = ReaderTypographyPreferences.PageMargin.defaultMargin.rawValue
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.theme))
    private var themeRaw: String = ReaderTypographyPreferences.Theme.default.rawValue
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.justify))
    private var justify: Bool = true
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.twoPageLayout))
    private var twoPageLayout: Bool = false
    @Shared(.appStorage(ReaderPreferenceKeys.pageTransition))
    private var pageTransitionRaw: String = ReaderPageTransition.curl.rawValue

    private var pageTransition: ReaderPageTransition {
        ReaderPageTransition(rawValue: pageTransitionRaw) ?? .curl
    }

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                fontSizeSection
                fontFamilySection
                lineHeightSection
                pageMarginSection
                twoPageSection
                justifySection
                pageTransitionSection
            }
            .navigationTitle("Reading Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneButton }
        }
        .presentationDetents([.large])
    }

    /// Page-turn effect, matching Apple Books' four options.
    ///
    /// Each option is shown with a one-line explanation of what it costs,
    /// because Curl has a real trade-off: UIKit's page-curl controller drops
    /// its interactive pan, so a drag no longer turns a chapter.
    private var pageTransitionSection: some View {
        Section {
            ForEach(ReaderPageTransition.allCases) { option in
                Button {
                    $pageTransitionRaw.withLock { $0 = option.rawValue }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.systemImage)
                            .amgiFont(.body)
                            .frame(width: 26)
                            .foregroundStyle(
                                pageTransition == option ? palette.accent : palette.textSecondary
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .amgiFont(.body)
                                .foregroundStyle(palette.textPrimary)
                            if !option.supportsInteractivePan {
                                Text("Swipe to turn a chapter is disabled; use the page edges or arrow keys.")
                                    .amgiFont(.micro)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if pageTransition == option {
                            Image(systemName: "checkmark")
                                .amgiFont(.bodyEmphasis)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(
                    pageTransition == option ? [.isSelected] : []
                )
            }
        } header: {
            Text("Page Transition")
        } footer: {
            Text("Curl is the default. Intra-chapter turns always use a swipe.")
        }
    }

    // MARK: - Sections

    private var themeSection: some View {
        Section {
            HStack(spacing: 18) {
                ForEach(ReaderTypographyPreferences.Theme.allCases) { option in
                    ThemeSwatchButton(
                        theme: option,
                        isSelected: themeRaw == option.rawValue,
                        action: { $themeRaw.withLock { $0 = option.rawValue } }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    private var fontSizeSection: some View {
        Section {
            HStack {
                Button { decreaseFontSize() } label: {
                    Image(systemName: "textformat.size.smaller")
                        .amgiFont(.cardTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(fontSize <= 12)
                .accessibilityLabel("Decrease text size")

                Text("\(fontSize) pt")
                    .amgiFont(.body, .monospacedDigits)
                    .frame(width: 64)

                Button { increaseFontSize() } label: {
                    Image(systemName: "textformat.size.larger")
                        .amgiFont(.cardTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(fontSize >= 28)
                .accessibilityLabel("Increase text size")
            }
        } header: {
            Label("Font Size", systemImage: "textformat.size")
        }
    }

    private var fontFamilySection: some View {
        Section {
            Picker("Font", selection: fontFamilyBinding) {
                ForEach(ReaderTypographyPreferences.FontFamily.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Label("Font", systemImage: "textformat")
        }
    }

    private var lineHeightSection: some View {
        Section {
            Stepper(value: lineHeightBinding, in: 1.2...2.0, step: 0.1) {
                HStack {
                    Text("Line Height")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.1f", lineHeight))
                        .amgiFont(.body, .monospacedDigits)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        } header: {
            Label("Spacing", systemImage: "arrow.up.and.down.text.horizontal")
        }
    }

    private var pageMarginSection: some View {
        Section {
            Picker("Margins", selection: pageMarginBinding) {
                ForEach(ReaderTypographyPreferences.PageMargin.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Label("Margins", systemImage: "rectangle.compress.vertical")
        }
    }

    private var twoPageSection: some View {
        Section {
            Toggle(isOn: twoPageBinding) {
                Label("Two-Page Layout", systemImage: "rectangle.split.2x1")
            }
        } footer: {
            Text("Uses two pages in wide landscape windows and automatically returns to one page in compact or portrait layouts.")
        }
    }

    private var justifySection: some View {
        Section {
            Toggle(isOn: justifyBinding) {
                Label("Justify Text", systemImage: "text.justify")
            }
        }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
                .fontWeight(.semibold)
        }
    }

    // MARK: - Bindings

    private var fontFamilyBinding: Binding<ReaderTypographyPreferences.FontFamily> {
        Binding(
            get: { ReaderTypographyPreferences.FontFamily(rawValue: fontFamilyRaw) ?? .system },
            set: { value in $fontFamilyRaw.withLock { $0 = value.rawValue } }
        )
    }

    private var pageMarginBinding: Binding<ReaderTypographyPreferences.PageMargin> {
        Binding(
            get: { ReaderTypographyPreferences.PageMargin(rawValue: pageMarginRaw) ?? .defaultMargin },
            set: { value in $pageMarginRaw.withLock { $0 = value.rawValue } }
        )
    }

    private var lineHeightBinding: Binding<Double> {
        Binding(
            get: { lineHeight },
            set: { value in $lineHeight.withLock { $0 = value } }
        )
    }

    private var twoPageBinding: Binding<Bool> {
        Binding(
            get: { twoPageLayout },
            set: { newValue in $twoPageLayout.withLock { $0 = newValue } }
        )
    }

    private var justifyBinding: Binding<Bool> {
        Binding(
            get: { justify },
            set: { value in $justify.withLock { $0 = value } }
        )
    }
}

/// Single theme swatch button — a coloured circle with checkmark when
/// active, labelled below. Three of these sit in a horizontal row at the
/// top of the sheet, matching Apple Books' theme picker.
private struct ThemeSwatchButton: View {
    let theme: ReaderTypographyPreferences.Theme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                swatch
                Text(theme.label)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textPrimary)
            }
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(Text(theme.label))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var swatch: some View {
        ZStack {
            Circle()
                .fill(theme.backgroundColor)
                .frame(width: 44, height: 44)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? palette.accent : palette.textSecondary.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
            Text("Aa")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(ReaderThemeColor.color(fromHex: theme.foregroundHex, fallback: palette.textPrimary))
        }
    }
}

private extension ReaderTypographySettingsView {
    func decreaseFontSize() {
        $fontSize.withLock { $0 = max(12, $0 - 1) }
    }

    func increaseFontSize() {
        $fontSize.withLock { $0 = min(28, $0 + 1) }
    }
}

#if DEBUG

// MARK: - Preview

#Preview {
    NavigationStack { ReaderTypographySettingsView() }
}
#endif
