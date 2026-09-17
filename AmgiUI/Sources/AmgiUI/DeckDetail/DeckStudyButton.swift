public import SwiftUI
import AmgiTheme

/// Full-width native primary study button. Container manages any pending state.
public struct DeckStudyButton: View {
    public let isDisabled: Bool
    public let disabledHint: String
    public let onTap: () -> Void

    @Environment(\.palette) private var palette

    public init(
        isDisabled: Bool,
        disabledHint: String = "Deck has no cards due",
        onTap: @escaping () -> Void
    ) {
        self.isDisabled = isDisabled
        self.disabledHint = disabledHint
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            Text("Study Now")
                .amgiFont(size: 15, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(palette.accent)
        .disabled(isDisabled)
        .accessibilityLabel("Study now")
        .accessibilityHint(isDisabled ? disabledHint : "Start a review session")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Study button — enabled") {
    DeckStudyButton(isDisabled: false, onTap: {})
        .padding()
        .environment(\.palette, .vividLight)
}

#Preview("Study button — disabled") {
    DeckStudyButton(isDisabled: true, onTap: {})
        .padding()
        .environment(\.palette, .vividLight)
}
#endif
