import Foundation
import SwiftUI

/// Typography settings persisted across reader sessions and surfaced
/// through `ReaderTypographySettingsView`. Defaults reflect a warm,
/// Apple Books-like reading style: 17pt System font, 1.55 line-height,
/// default margin (24px), Default theme, justified text.
///
/// `@Shared(.appStorage(...))` is used at the view layer with these
/// keys; this enum is the single source for key names + value enums so
/// the sheet and the chapter VC agree on the schema.
enum ReaderTypographyPreferences {
    enum Keys {
        static let fontFamily = "reader_typo_font_family"
        static let fontSize = "reader_typo_font_size"
        static let lineHeight = "reader_typo_line_height"
        static let pageMargin = "reader_typo_page_margin"
        static let theme = "reader_typo_theme"
        static let justify = "reader_typo_justify"
        /// Optional two-page display. The reader still falls back to a
        /// single, capped page whenever the available window is compact or
        /// portrait, so the preference is safe on every device.
        static let twoPageLayout = "reader_typo_two_page_layout"
    }

    enum FontFamily: String, CaseIterable, Identifiable {
        /// Use whatever face the book embeds. The default, and what Apple
        /// Books does: a textbook or a novel carries its own typography, and
        /// substituting the system sans flattens it.
        case book
        case system, serif, sansSerif, mono
        var id: String { rawValue }

        /// CSS font-family stack pushed into `--reader-font-family`.
        ///
        /// Empty for `.book`, which is the signal the stylesheet uses to leave
        /// the book's own `font-family` alone — see the
        /// `--reader-honour-book-font` gate in EPUBReaderStyles.css.
        var cssStack: String {
            switch self {
            case .book:      return ""
            case .system:    return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
            case .serif:     return "\"New York\", Georgia, \"Times New Roman\", serif"
            case .sansSerif: return "\"Helvetica Neue\", \"Avenir Next\", sans-serif"
            case .mono:      return "\"SF Mono\", Menlo, Consolas, monospace"
            }
        }

        var label: String {
            switch self {
            case .book: return "Book"
            case .system: return "System"
            case .serif: return "Serif"
            case .sansSerif: return "Sans"
            case .mono: return "Mono"
            }
        }
    }

    enum PageMargin: String, CaseIterable, Identifiable {
        case compact, defaultMargin = "default", loose
        var id: String { rawValue }

        var pixels: Int {
            switch self {
            case .compact: return 12
            case .defaultMargin: return 24
            case .loose: return 40
            }
        }

        var label: String {
            switch self {
            case .compact: return "Compact"
            case .defaultMargin: return "Default"
            case .loose: return "Loose"
            }
        }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case `default`, sepia, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .default: return "Default"
            case .sepia: return "Sepia"
            case .dark: return "Dark"
            }
        }

        /// Hex strings consumed by the WebView CSS custom properties.
        var backgroundHex: String {
            switch self {
            case .default: return "#FAF7F1"
            case .sepia:   return "#F4ECD8"
            case .dark:    return "#1B1B1F"
            }
        }

        var foregroundHex: String {
            switch self {
            case .default: return "#1A1A1A"
            case .sepia:   return "#5B4636"
            case .dark:    return "#E8E6E3"
            }
        }

        /// Press tint for a token, shown only while a finger is on the word.
        /// There is deliberately no persistent underline: a decoration on every
        /// word makes the page unreadable.
        var pressTintCSS: String {
            switch self {
            case .default: return "rgba(90, 90, 90, 0.20)"
            case .sepia:   return "rgba(123, 84, 60, 0.20)"
            case .dark:    return "rgba(210, 210, 220, 0.24)"
            }
        }

        /// SwiftUI background for the chrome / WKWebView so there is no
        /// flash of system colour while the chapter loads.
        var backgroundColor: Color {
            ReaderThemeColor.color(fromHex: backgroundHex, fallback: .white)
        }
    }
}
