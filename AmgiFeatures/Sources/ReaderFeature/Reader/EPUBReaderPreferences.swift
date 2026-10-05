import AmgiTheme
import AmgiUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Preferences owned by the EPUB reader so PDF and Anki-note reading keep
/// their existing appearance and navigation settings.
enum EPUBReaderPreferences {
    enum Keys {
#if os(macOS)
        // The existing Mac EPUB style sheet is shared with the wider reader.
        // Keep its storage keys wired up so this UI work does not strand the
        // desktop controls; iPhone and iPad use EPUB-only keys below.
        static let theme = ReaderTypographyPreferences.Keys.theme
        static let fontFamily = ReaderTypographyPreferences.Keys.fontFamily
        static let fontSize = ReaderTypographyPreferences.Keys.fontSize
        static let lineHeight = ReaderTypographyPreferences.Keys.lineHeight
        static let pageMargin = ReaderTypographyPreferences.Keys.pageMargin
        static let justify = ReaderTypographyPreferences.Keys.justify
        static let twoPageLayout = ReaderTypographyPreferences.Keys.twoPageLayout
        static let pageTransition = ReaderPreferenceKeys.pageTransition
#else
        static let theme = "epub_reader_theme"
        static let fontFamily = "epub_reader_font_family"
        static let fontSize = "epub_reader_font_size"
        static let lineHeight = "epub_reader_line_height"
        static let pageMargin = "epub_reader_page_margin"
        static let justify = "epub_reader_justify"
        static let twoPageLayout = "epub_reader_two_page_layout"
        static let pageTransition = "epub_reader_page_transition"
#endif
        static let continuousScroll = "epub_reader_continuous_scroll"
        static let orientationLocked = "epub_reader_orientation_locked"
        static let verticalWriting = "epub_reader_vertical_writing"
    }

    enum Theme: String, CaseIterable, Identifiable {
        case original, quiet, paper, bold, calm, focus

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: "Original"
            case .quiet: "Quiet"
            case .paper: "Paper"
            case .bold: "Bold"
            case .calm: "Calm"
            case .focus: "Focus"
            }
        }

        var backgroundHex: String {
            switch self {
            case .original, .paper: "#FFFFFF"
            case .quiet: "#262626"
            case .bold: "#F8F8F6"
            case .calm: "#F3EBDD"
            case .focus: "#EDF3FC"
            }
        }

        var foregroundHex: String {
            switch self {
            case .original, .paper: "#222222"
            case .quiet: "#EEECE8"
            case .bold: "#101010"
            case .calm: "#514334"
            case .focus: "#23364C"
            }
        }

        var pressTintCSS: String {
            switch self {
            case .original, .paper: "rgba(90, 90, 90, 0.20)"
            case .quiet: "rgba(210, 210, 220, 0.24)"
            case .bold: "rgba(40, 40, 40, 0.18)"
            case .calm: "rgba(112, 83, 55, 0.20)"
            case .focus: "rgba(58, 91, 132, 0.20)"
            }
        }

        var tint: Color {
            ReaderThemeColor.color(fromHex: foregroundHex, fallback: .primary)
        }

        var background: Color {
            ReaderThemeColor.color(fromHex: backgroundHex, fallback: .white)
        }

        var backgroundColor: Color { background }
    }
}

/// The compact Reading Style panel used by the EPUB reader on iPhone and
/// iPad. EPUB preferences use their own keys so changing a book's appearance
/// does not change the PDF or note readers.
#if os(iOS)
struct EPUBReadingStylePanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @AppStorage(EPUBReaderPreferences.Keys.theme)
    private var themeRaw = EPUBReaderPreferences.Theme.original.rawValue

    @AppStorage(EPUBReaderPreferences.Keys.fontFamily)
    private var fontFamilyRaw = ReaderTypographyPreferences.FontFamily.book.rawValue
    @AppStorage(EPUBReaderPreferences.Keys.fontSize)
    private var fontSize = 17
    @AppStorage(EPUBReaderPreferences.Keys.lineHeight)
    private var lineHeight = 1.55
    @AppStorage(EPUBReaderPreferences.Keys.pageMargin)
    private var pageMarginRaw = ReaderTypographyPreferences.PageMargin.defaultMargin.rawValue
    @AppStorage(EPUBReaderPreferences.Keys.justify)
    private var justify = true
    @AppStorage(EPUBReaderPreferences.Keys.twoPageLayout)
    private var twoPageLayout = true
    @AppStorage(EPUBReaderPreferences.Keys.pageTransition)
    private var pageTransitionRaw = ReaderPageTransition.curl.rawValue
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var customize = false

    private var selectedTheme: EPUBReaderPreferences.Theme {
        EPUBReaderPreferences.Theme(rawValue: themeRaw) ?? .original
    }

    private var selectedFont: ReaderTypographyPreferences.FontFamily {
        ReaderTypographyPreferences.FontFamily(rawValue: fontFamilyRaw) ?? .book
    }

    private var selectedMargin: ReaderTypographyPreferences.PageMargin {
        ReaderTypographyPreferences.PageMargin(rawValue: pageMarginRaw) ?? .defaultMargin
    }

    private var selectedPageTransition: ReaderPageTransition {
        ReaderPageTransition(rawValue: pageTransitionRaw) ?? .curl
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            fontSizeStepper
            brightnessControl
            themePicker
            if customize { customizationControls }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { customize.toggle() }
            } label: {
                Label(customize ? "Done Customizing" : "Customize", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(palette.surfaceElevated, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: brightness) { _, value in UIScreen.main.brightness = CGFloat(value) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(palette.textSecondary)
            }
            .accessibilityLabel("Close reading settings")
            Spacer()
            Text("Themes & Settings").amgiFont(.bodyEmphasis)
            Spacer()
            Color.clear.frame(width: 27, height: 27)
        }
    }

    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            Button { if fontSize > 12 { fontSize -= 1 } } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(maxWidth: .infinity, minHeight: 45)
            }
            .disabled(fontSize <= 12)
            Text("A")
                .frame(maxWidth: .infinity)
            Divider().frame(height: 32)
            Text("A").font(.system(size: 19, weight: .semibold))
                .frame(maxWidth: .infinity)
            Button { if fontSize < 36 { fontSize += 1 } } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(maxWidth: .infinity, minHeight: 45)
            }
            .disabled(fontSize >= 36)
        }
        .foregroundStyle(palette.textPrimary)
        .background(palette.surfaceElevated, in: Capsule())
    }

    private var brightnessControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
            Slider(value: $brightness, in: 0.15...1)
            Image(systemName: "sun.max.fill")
        }
        .foregroundStyle(palette.textSecondary)
    }

    private var themePicker: some View {
        HStack(spacing: 9) {
            ForEach(EPUBReaderPreferences.Theme.allCases) { theme in
                Button {
                    themeRaw = theme.rawValue
                } label: {
                    VStack(spacing: 5) {
                        Text("Aa")
                            .font(.system(size: 20, weight: theme == .bold ? .bold : .regular, design: .serif))
                            .foregroundStyle(ReaderThemeColor.color(fromHex: theme.foregroundHex, fallback: .primary))
                        Text(theme.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .foregroundStyle(ReaderThemeColor.color(fromHex: theme.foregroundHex, fallback: .primary))
                    }
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(theme.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                        selectedTheme == theme ? palette.accent : palette.separator,
                        lineWidth: selectedTheme == theme ? 2 : 0.6
                    ))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.title) reading theme")
            }
        }
    }

    @ViewBuilder
    private var customizationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Font", selection: Binding(
                get: { selectedFont },
                set: { value in fontFamilyRaw = value.rawValue }
            )) {
                ForEach(ReaderTypographyPreferences.FontFamily.allCases) { font in
                    Text(font.label).tag(font)
                }
            }
            Picker("Margins", selection: Binding(
                get: { selectedMargin },
                set: { value in pageMarginRaw = value.rawValue }
            )) {
                ForEach(ReaderTypographyPreferences.PageMargin.allCases) { margin in
                    Text(margin.label).tag(margin)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Line spacing"); Spacer(); Text(lineHeight, format: .number.precision(.fractionLength(2))) }
                    .font(.footnote)
                Slider(value: Binding(
                    get: { lineHeight },
                    set: { value in lineHeight = value }
                ), in: 1.2...2.0, step: 0.05)
            }
            Toggle("Justify text", isOn: Binding(
                get: { justify }, set: { value in justify = value }
            ))
            Toggle("Two-page spread", isOn: Binding(
                get: { twoPageLayout }, set: { value in twoPageLayout = value }
            ))
            Picker("Page turn", selection: Binding(
                get: { selectedPageTransition },
                set: { value in pageTransitionRaw = value.rawValue }
            )) {
                ForEach([ReaderPageTransition.curl, .slide, .fastFade]) { transition in
                    Label(transition.label, systemImage: transition.systemImage).tag(transition)
                }
            }
        }
        .font(.footnote)
        .tint(palette.accent)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
#endif
