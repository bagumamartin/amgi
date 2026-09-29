import AmgiTheme
import AmgiUI
import Sharing
import SwiftUI

/// Apple Books-style Reading Style & Themes sheet.
///
/// Provides quick controls for:
/// - Theme palettes (Default, Sepia, Dark).
/// - Text size with stepped A / A controls.
/// - Font family selection.
/// - Continuous scroll vs paginated navigation (Curl / Slide / Fast Fade).
/// - Text justification and 2-page spread layout.
struct ReaderStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @Shared(.appStorage(ReaderTypographyPreferences.Keys.fontFamily))
    private var fontFamilyRaw: String = ReaderTypographyPreferences.FontFamily.book.rawValue
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

    private var isPDF: Bool

    init(isPDF: Bool = false) {
        self.isPDF = isPDF
    }

    private var pageTransition: ReaderPageTransition {
        ReaderPageTransition(rawValue: pageTransitionRaw) ?? .curl
    }

    private var selectedTheme: ReaderTypographyPreferences.Theme {
        ReaderTypographyPreferences.Theme(rawValue: themeRaw) ?? .default
    }

    private var selectedFontFamily: ReaderTypographyPreferences.FontFamily {
        ReaderTypographyPreferences.FontFamily(rawValue: fontFamilyRaw) ?? .book
    }

    var body: some View {
        NavigationStack {
            List {
                // Theme Swatches
                Section {
                    themeRow
                } header: {
                    Text("Theme")
                }

                // Page Navigation / Scroll Mode
                Section {
                    pageModePicker
                    if pageTransition != .scroll {
                        transitionPicker
                    }
                } header: {
                    Text("Page Navigation")
                }

                // Font Size & Family (Relevant for reflowable EPUB)
                if !isPDF {
                    Section {
                        fontSizeRow
                        fontFamilyPicker
                    } header: {
                        Text("Typography")
                    }

                    Section {
                        Toggle("Justify Text", isOn: Binding($justify))
                        Toggle("Two-Page Spread (Landscape)", isOn: Binding($twoPageLayout))
                    } header: {
                        Text("Layout")
                    }
                }
            }
            .navigationTitle("Themes & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Sections

    private var themeRow: some View {
        HStack(spacing: 16) {
            ForEach(ReaderTypographyPreferences.Theme.allCases) { theme in
                Button {
                    $themeRaw.withLock { $0 = theme.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(theme.backgroundColor)
                            .frame(width: 48, height: 48)
                            .overlay(
                                Circle()
                                    .stroke(
                                        selectedTheme == theme ? palette.accent : palette.separator,
                                        lineWidth: selectedTheme == theme ? 3 : 1
                                    )
                            )
                            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)

                        Text(theme.label)
                            .amgiFont(selectedTheme == theme ? .captionBold : .caption)
                            .foregroundStyle(selectedTheme == theme ? palette.accent : palette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    private var pageModePicker: some View {
        Picker("Navigation Mode", selection: Binding(
            get: { pageTransition == .scroll ? "scroll" : "paged" },
            set: { mode in
                if mode == "scroll" {
                    $pageTransitionRaw.withLock { $0 = ReaderPageTransition.scroll.rawValue }
                } else {
                    $pageTransitionRaw.withLock { $0 = ReaderPageTransition.curl.rawValue }
                }
            }
        )) {
            Text("Paged").tag("paged")
            Text("Continuous Scroll").tag("scroll")
        }
        .pickerStyle(.segmented)
    }

    private var transitionPicker: some View {
        ForEach([ReaderPageTransition.curl, .slide, .fastFade]) { option in
            Button {
                $pageTransitionRaw.withLock { $0 = option.rawValue }
            } label: {
                HStack {
                    Image(systemName: option.systemImage)
                        .frame(width: 24)
                        .foregroundStyle(pageTransition == option ? palette.accent : palette.textSecondary)

                    Text(option.label)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)

                    Spacer()

                    if pageTransition == option {
                        Image(systemName: "checkmark")
                            .amgiFont(.bodyEmphasis)
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var fontSizeRow: some View {
        HStack(spacing: 16) {
            Button {
                if fontSize > 12 {
                    $fontSize.withLock { $0 -= 1 }
                }
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .disabled(fontSize <= 12)

            Text("\(fontSize) pt")
                .amgiFont(.body, .monospacedDigits)
                .frame(width: 60)

            Button {
                if fontSize < 36 {
                    $fontSize.withLock { $0 += 1 }
                }
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 19, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .disabled(fontSize >= 36)
        }
    }

    private var fontFamilyPicker: some View {
        Picker("Font", selection: Binding(
            get: { selectedFontFamily },
            set: { newFamily in $fontFamilyRaw.withLock { $0 = newFamily.rawValue } }
        )) {
            ForEach(ReaderTypographyPreferences.FontFamily.allCases) { family in
                Text(family.label).tag(family)
            }
        }
    }
}
