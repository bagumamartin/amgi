import SwiftUI
import AmgiTheme

/// Bottom-of-screen toast surfaced after a successful filtered-deck rebuild.
/// `feedback == nil` hides the banner; the container animates the change.
struct RebuildFeedbackBanner: View {
    let feedback: String?

    @Environment(\.palette) private var palette

    var body: some View {
        if let feedback {
            Text(feedback)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.accent, in: Capsule())
                .padding(.bottom, 24)
                .transition(AmgiMotion.slide(from: .bottom))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
