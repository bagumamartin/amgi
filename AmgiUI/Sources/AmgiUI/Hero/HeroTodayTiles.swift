public import SwiftUI
import AmgiTheme

/// Today's-stats tiles for the hero, adapted from the Onigiri add-on's
/// dashboard cards (same revlog-derived values via `HeroTodayStats`).
/// One shared tile chrome; the hero composes them into the eyebrow row
/// (Studied/Time), the numeral row (Pace) and the footer band (Retention).
struct HeroHeaderStatTiles: View {
    let today: HeroTodayStats

    var body: some View {
        HStack(spacing: 6) {
            HeroStatTile(
                eyebrow: "Studied",
                value: today.studied == 1 ? "1 card" : "\(today.studied) cards",
                accessibilityLabel: "Studied, \(today.studied == 1 ? "1 card" : "\(today.studied) cards")",
                valueFontSize: 13,
                verticalPadding: 6,
                horizontalPadding: 2
            )
            HeroStatTile(
                eyebrow: "Time",
                value: String(format: "%.1f min", Double(today.timeMillis) / 60_000),
                accessibilityLabel: "Time studied, \(String(format: "%.1f min", Double(today.timeMillis) / 60_000))",
                valueFontSize: 13,
                verticalPadding: 6,
                horizontalPadding: 2
            )
        }
    }
}

/// Retention alone: percent and stars share one row so the tile stays the
/// same height as the value-only tiles, with a few points of air between
/// the figure and the star group.
struct HeroRetentionTile: View {
    let today: HeroTodayStats

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 3) {
            Text("RETENTION")
                .amgiFont(size: 10, weight: .semibold, tracking: 0.4, relativeTo: .caption)
                .foregroundStyle(palette.textTertiary)
            HStack(spacing: 10) {
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            palette.surface,
            in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Retention, \(String(format: "%.0f%%", today.retentionPercent))")
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

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 3) {
            Text(eyebrow.uppercased())
                .amgiFont(size: 10, weight: .semibold, tracking: 0.4, relativeTo: .caption)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .amgiFont(size: valueFontSize, weight: .semibold, relativeTo: .body)
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
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

#Preview("Retention band") {
    HeroRetentionTile(today: .sample)
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}

#Preview("Retention band — unreviewed") {
    HeroRetentionTile(today: HeroTodayStats(studied: 3, timeMillis: 128_100))
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .environment(\.palette, .vividLight)
}
#endif
