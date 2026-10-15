public import SwiftUI
public import CoreGraphics
import AmgiTheme

/// A card colour taken from a book's cover, the way Apple Books tints its
/// Continue cards: navy for a navy cover, oxblood for a red one, slate for a
/// pale scan. Always dark enough for white text, so every card reads the same
/// way whatever the cover looks like.
public struct CoverTint: Equatable, Sendable {
    /// Top-leading end of the card's gradient.
    public let base: Color
    /// Bottom-trailing end — the same hue, a step darker.
    public let deep: Color

    /// Before a cover has been sampled: a neutral slate rather than a guess
    /// at a hue that may be wrong.
    public static let neutral = CoverTint(hue: 0.6, saturation: 0.08, brightness: 0.42)

    init(hue: Double, saturation: Double, brightness: Double) {
        base = Color(hue: hue, saturation: saturation, brightness: brightness)
        deep = Color(hue: hue, saturation: min(1, saturation * 1.1), brightness: brightness * 0.72)
    }

    /// Generated placeholder covers have no pixels worth sampling; take the
    /// darker end of the palette the placeholder itself is drawn from.
    public static func placeholder(seed: String) -> CoverTint {
        let palette = BookCoverPalette.resolve(seed: seed)
        return CoverTint(sampling: palette.gradientEnd) ?? .neutral
    }

    /// Samples the cover's dominant colour. Saturated pixels count for more
    /// than greys, so a strong band of colour on a mostly white cover still
    /// wins — a plain average of most covers is mud.
    public init?(image: CGImage) {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        var brightnessSum = 0.0, counted = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[index]) / 255 / alpha
            let g = Double(pixels[index + 1]) / 255 / alpha
            let b = Double(pixels[index + 2]) / 255 / alpha
            let maxC = max(r, g, b), minC = min(r, g, b)
            brightnessSum += maxC
            counted += 1
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            let weight = 0.15 + saturation * saturation * 4
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return nil }
        self.init(
            red: red / total,
            green: green / total,
            blue: blue / total,
            coverBrightness: brightnessSum / counted
        )
    }

    private init?(sampling color: Color) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.init(red: Double(r), green: Double(g), blue: Double(b), coverBrightness: nil)
        #else
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), coverBrightness: nil)
        #endif
    }

    /// Keeps the hue, tames the rest: brightness is held in a band where
    /// white text always reads, and near-greys stay grey instead of being
    /// pushed into a hue they only hint at.
    ///
    /// `coverBrightness` is the cover's overall brightness. The card keeps the
    /// cover's hue but never its brightness: a card the same navy as a navy
    /// cover swallows the thumbnail. Most covers get a deeper card beneath
    /// them; covers already near-black get a lifted one.
    private init(red: Double, green: Double, blue: Double, coverBrightness: Double?) {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC == 0 ? 0 : delta / maxC
        var brightness = min(max(maxC * 0.7, 0.24), 0.46)
        if let cover = coverBrightness {
            let separation = 0.18
            if abs(brightness - cover) < separation {
                brightness = cover >= 0.3
                    ? max(cover - separation, 0.13)
                    : min(cover + separation, 0.5)
            }
        }
        self.init(
            hue: hue,
            saturation: saturation < 0.12 ? saturation * 0.5 : min(saturation, 0.78),
            brightness: brightness
        )
    }
}

public extension CoverTint {
    /// Title and author on a tinted card.
    static let primaryText = Color.white
    /// The quieter status line ("Book • 54%").
    static let secondaryText = Color.white.opacity(0.62)
}

public extension View {
    /// The tinted backdrop of a Continue card.
    func coverTintedCard(_ tint: CoverTint) -> some View {
        let shape = RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous)
        return background(
            LinearGradient(
                colors: [tint.base, tint.deep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: shape
        )
        .contentShape(shape)
    }
}
