public import SwiftUI
import AmgiTheme

/// Learning cards are still due later today. Wait leaves them. Do them now
/// pulls them into the queue. Check ready is only offered from inside a session.
public struct SessionCoolingCard: View {
    let count: Int
    let onWait: () -> Void
    let onDoNow: () -> Void
    let onCheckReady: (() -> Void)?

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    public init(
        count: Int,
        onWait: @escaping () -> Void,
        onDoNow: @escaping () -> Void,
        onCheckReady: (() -> Void)? = nil
    ) {
        self.count = count
        self.onWait = onWait
        self.onDoNow = onDoNow
        self.onCheckReady = onCheckReady
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.md) {
            AmgiCard {
                VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                    Text("\(count)")
                        .amgiFont(.displayHero)
                        .foregroundStyle(palette.textPrimary)
                        .monospacedDigit()
                    Text(count == 1
                         ? AmgiL10n.text("1 learning card returns later today", locale: locale)
                         : AmgiL10n.format("%lld learning cards return later today", [count], locale: locale))
                        .amgiFont(.body)
                        .foregroundStyle(palette.textSecondary)
                    Text(AmgiL10n.text("Wait, or study them now.", locale: locale))
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(AmgiL10n.text("Do them now", locale: locale), action: onDoNow)
                .buttonStyle(AmgiPrimaryButtonStyle())

            Button(AmgiL10n.text("Wait", locale: locale), action: onWait)
                .buttonStyle(AmgiSecondaryButtonStyle())

            if let onCheckReady {
                Button(AmgiL10n.text("Check ready cards", locale: locale), action: onCheckReady)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
