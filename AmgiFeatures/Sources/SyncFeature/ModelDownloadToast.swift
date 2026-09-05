import SwiftUI
import AmgiTheme
import AmgiUI

/// Bottom toast for the e5 model download. Same capsule/material language as
/// `SyncToast`; failure carries a Retry action, the other kinds are
/// informational and auto-dismissed by the coordinator.
struct ModelDownloadToast: View {
    enum Kind: Equatable {
        case progress(String)
        case success(String)
        case failure(String)
    }

    @Environment(\.palette) private var palette

    let kind: Kind
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .progress(let message):
                ProgressView()
                    .controlSize(.small)
                Text(message)
            case .success(let message):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.positive)
                Text(message)
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.warning)
                Text(message)
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .amgiFont(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .amgiMaterial(.light, in: Capsule())
        // No hairline overlay: matches SyncToast — `amgiMaterialElevation`
        // draws the ring under glass and a second stroke double-drew it.
        .amgiMaterialElevation(Capsule(), radius: 8, y: 2, opacity: 0.12)
        .padding(.bottom, 12)
    }
}

extension View {
    /// Bottom-edge stack for both toasts. One overlay (not two) so sync and
    /// model progress never cover each other.
    func combinedToastOverlay(
        sync: SyncToast.Kind?,
        model: ModelDownloadToast.Kind?,
        onModelRetry: @escaping () -> Void
    ) -> some View {
        overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let model {
                    ModelDownloadToast(kind: model, onRetry: onModelRetry)
                        .transition(AmgiMotion.slide(from: .bottom))
                }
                if let sync {
                    SyncToast(kind: sync)
                        .transition(AmgiMotion.slide(from: .bottom))
                }
            }
        }
        // Either success is worth a haptic (mirrors `syncToastOverlay`).
        // Progress updates are not — they'd fire repeatedly and train the
        // user to ignore the channel.
        .sensoryFeedback(trigger: sync) { _, new in
            if case .success = new { .success } else { nil }
        }
        .sensoryFeedback(trigger: model) { _, new in
            if case .success = new { .success } else { nil }
        }
        .animation(AmgiMotion.momentum, value: combinedToastIdentity(sync: sync, model: model))
    }

    private func combinedToastIdentity(
        sync: SyncToast.Kind?,
        model: ModelDownloadToast.Kind?
    ) -> String {
        "\(String(describing: sync))|\(String(describing: model))"
    }
}
