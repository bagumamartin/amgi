public import SwiftUI
import AmgiTheme

/// Today's-stats tiles for the hero, adapted from the Onigiri add-on's
/// dashboard cards (same revlog-derived values via `HeroTodayStats`).
/// One shared tile chrome; the hero stacks them in its right column:
/// Studied/Time, then Pace, then Retention, all the same width.
struct HeroHeaderStatTiles: View {
    let today: HeroTodayStats

    var body: some View {
        HStack(spacing: 6) {
            HeroStudiedTile(today: today)
            HeroTimeTile(today: today)
        }
    }
}

/// Today's answer count. Separate from `HeroHeaderStatTiles` so the wide
/// hero can lay Studied, Time, Pace and Retention out as four equal tiles.
struct HeroStudiedTile: View {
    let today: HeroTodayStats
    var fillsHeight = false

    @Environment(\.locale) private var locale

    var body: some View {
        let value = today.studied == 1
            ? AmgiL10n.text("1 card", locale: locale)
            : AmgiL10n.format("%lld cards", [today.studied], locale: locale)
        HeroStatTile(
            eyebrow: AmgiL10n.text("Studied", locale: locale),
            value: value,
            accessibilityLabel: AmgiL10n.format("Studied, %@", [value], locale: locale),
            valueFontSize: 13,
            verticalPadding: 6,
            horizontalPadding: 2,
            fillsHeight: fillsHeight
        )
    }
}

/// Today's study time.
struct HeroTimeTile: View {
    let today: HeroTodayStats
    var fillsHeight = false

    @Environment(\.locale) private var locale

    var body: some View {
        let value = AmgiL10n.format("%.1f min", [Double(today.timeMillis) / 60_000], locale: locale)
        HeroStatTile(
            eyebrow: AmgiL10n.text("Time", locale: locale),
            value: value,
            accessibilityLabel: AmgiL10n.format("Time studied, %@", [value], locale: locale),
            valueFontSize: 13,
            verticalPadding: 6,
            horizontalPadding: 2,
            fillsHeight: fillsHeight
        )
    }
}

/// Retention: percent and stars share one row so the tile stays the same
/// height as the value-only tiles, and fits the Pace tile's width.
struct HeroRetentionTile: View {
    let today: HeroTodayStats

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 3) {
            Text(AmgiL10n.text("Retention", locale: locale).uppercased(with: locale))
                .amgiFont(size: 10, weight: .semibold, tracking: 0.4, relativeTo: .caption)
                .foregroundStyle(palette.textTertiary)
            HStack(spacing: 6) {
                Text(String(format: "%.0f%%", today.retentionPercent))
                    .amgiFont(size: 14, weight: .semibold, relativeTo: .body)
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(index < today.filledStars ? palette.warning : palette.separator)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        // Fills its grid row so it matches the streak chip beside it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            palette.surface,
            in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AmgiL10n.format("Retention, %@", [String(format: "%.0f%%", today.retentionPercent)], locale: locale))
    }
}

/// One stat tile: uppercase eyebrow over a single value row. Equal widths
/// come from the parent `HStack` (`maxWidth: .infinity` each); equal heights
/// hold because every tile is exactly two rows — callers must keep values
/// (and the retention stars) on one line.
struct HeroStatTile: View {
    let eyebrow: String
    let value: String
    let accessibilityLabel: String
    let valueFontSize: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    /// Stretch to the row's height. The wide hero's 2×2 grid matches the due
    /// column beside it; the iPhone grid keeps the tiles at their ideal size.
    var fillsHeight = false

    @Environment(\.palette) private var palette

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 3) {
            Text(eyebrow.uppercased(with: locale))
                .amgiFont(size: 10, weight: .semibold, tracking: 0.4, relativeTo: .caption)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .amgiFont(size: valueFontSize, weight: .semibold, relativeTo: .body)
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(
            palette.surface,
            in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
}

#if DEBUG
#Preview("Header tiles") {
    HeroHeaderStatTiles(today: .sample)
        .padding(16)
        .frame(width: 360)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}

#Preview("Retention tile") {
    HeroRetentionTile(today: .sample)
        .padding(16)
        .frame(width: 180)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}

#Preview("Retention tile — unreviewed") {
    HeroRetentionTile(today: HeroTodayStats(studied: 3, timeMillis: 128_100))
        .padding(16)
        .frame(width: 180)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}
#endif
