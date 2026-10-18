import AmgiTheme
import AmgiUI
import SwiftUI

/// A provider's own mark on its brand tile: the OpenAI blossom in black and
/// white, Claude's spark in terracotta on ivory, Apple Intelligence's glyph
/// in its spectrum. Brand colours are deliberate here, not palette roles.
struct ProviderMark: View {
    let provider: AssistantProvider
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.palette) private var palette

    /// Anthropic's Claude terracotta and ivory.
    static let claudeTerracotta = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let claudeIvory = Color(red: 0xF0 / 255, green: 0xEE / 255, blue: 0xE6 / 255)
    static let appleSpectrum = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.62, blue: 0.24), Color(red: 0.98, green: 0.33, blue: 0.53),
            Color(red: 0.69, green: 0.38, blue: 0.98), Color(red: 0.25, green: 0.56, blue: 1.0),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            switch provider {
            case .apple:
                Image(systemName: "apple.intelligence")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(Self.appleSpectrum)
                    .frame(width: size, height: size)
                    .background(palette.background, in: tile)
            case .chatGPT, .openAI:
                // Black on white in dark mode, white on black in light — the
                // approved sign-in formats' pairing.
                ChatGPTLogo(size: size * 0.55)
                    .foregroundStyle(colorScheme == .dark ? ChatGPTBrand.ink : ChatGPTBrand.paper)
                    .frame(width: size, height: size)
                    .background(colorScheme == .dark ? ChatGPTBrand.paper : ChatGPTBrand.ink, in: tile)
            case .anthropic:
                ClaudeLogo(size: size * 0.6)
                    .foregroundStyle(Self.claudeTerracotta)
                    .frame(width: size, height: size)
                    .background(Self.claudeIvory, in: tile)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Claude's spark, as a template.
struct ClaudeLogo: View {
    var size: CGFloat = 20

    var body: some View {
        Image("ClaudeLogo", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The small inline mark for menus and chips.
struct ProviderGlyph: View {
    let provider: AssistantProvider
    var size: CGFloat = 13

    var body: some View {
        switch provider {
        case .apple:
            Image(systemName: "apple.intelligence").font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(ProviderMark.appleSpectrum)
        case .chatGPT, .openAI:
            ChatGPTLogo(size: size)
        case .anthropic:
            ClaudeLogo(size: size).foregroundStyle(ProviderMark.claudeTerracotta)
        }
    }
}
