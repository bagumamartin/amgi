import AmgiTheme
import AmgiUI
import SwiftUI

/// Shown while the collection could not be opened at launch — normally
/// because an AI assistant's helper session holds it. Auto-retries every
/// 2 s; the moment the open succeeds the real app appears.
struct CollectionBusyView: View {
    @State private var launch = CollectionLaunchState.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: AmgiSpacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Amgi is busy")
                .font(.title2.weight(.semibold))
            Text(
                "An AI assistant is using your collection right now. "
                    + "Amgi will open automatically when it's free — no action needed. "
                    + "You can also quit the assistant to free it immediately."
            )
            .font(.callout)
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            if let error = launch.openError {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button("Try opening now") {
                launch.retryNow()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(AmgiSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
