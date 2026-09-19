import SwiftUI
import AmgiTheme
import AmgiUI

/// Bottom toast for the e5 model download.
/// Shows determinate progress with progress bar, percentage, and byte counts,
/// distinct sub-stages (verifying, extracting, compiling), and polished success/failure states.
struct ModelDownloadToast: View {
    enum Stage: Equatable, Sendable {
        case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64?)
        case verifying
        case extracting
        case compiling

        var fraction: Double {
            if case .downloading(let f, _, _) = self { return f }
            return 0
        }

        var title: String {
            switch self {
            case .downloading: return "Downloading AI Model"
            case .verifying:   return "Verifying Download…"
            case .extracting:  return "Extracting Model…"
            case .compiling:   return "Compiling Neural Engine…"
            }
        }
    }

    enum Kind: Equatable, Sendable {
        case progress(Stage)
        case success(title: String, subtitle: String?)
        case failure(message: String, reason: String?)
    }

    @Environment(\.palette) private var palette

    let kind: Kind
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}

    private let shape = RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            switch kind {
            case .progress(let stage):
                progressContent(stage: stage)
            case .success(let title, let subtitle):
                successContent(title: title, subtitle: subtitle)
            case .failure(let message, let reason):
                failureContent(message: message, reason: reason)
            }
        }
        .padding(.horizontal, AmgiSpacing.md)
        .padding(.vertical, AmgiSpacing.md)
        .frame(maxWidth: 380)
        .amgiMaterial(.light, in: shape)
        .amgiMaterialElevation(shape, radius: 10, y: 3, opacity: 0.14)
        .padding(.bottom, 12)
    }

    // MARK: - Progress View

    @ViewBuilder
    private func progressContent(stage: Stage) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            HStack(spacing: AmgiSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)

                Text(stage.title)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: AmgiSpacing.xs)

                if case .downloading(let fraction, _, _) = stage {
                    Text("\(Int(fraction * 100))%")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                        .monospacedDigit()
                }

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }

            if case .downloading(let fraction, let received, let total) = stage {
                ProgressView(value: fraction)
                    .tint(palette.accent)
                    .animation(AmgiMotion.quick, value: fraction)

                HStack {
                    Text("\(formatBytes(received)) / \(formatBytes(total ?? 0))")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()

                    Spacer()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
            }
        }
    }

    // MARK: - Success View

    @ViewBuilder
    private func successContent(title: String, subtitle: String?) -> some View {
        HStack(spacing: AmgiSpacing.md) {
            ZStack {
                Circle()
                    .fill(palette.positive.opacity(0.15))
                    .frame(width: 30, height: 30)

                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.positive)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            Spacer(minLength: AmgiSpacing.xs)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    // MARK: - Failure View

    @ViewBuilder
    private func failureContent(message: String, reason: String?) -> some View {
        HStack(alignment: .top, spacing: AmgiSpacing.md) {
            ZStack {
                Circle()
                    .fill(palette.warning.opacity(0.15))
                    .frame(width: 30, height: 30)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.warning)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)

                if let reason, !reason.isEmpty {
                    Text(reason)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: AmgiSpacing.xs)

            HStack(spacing: AmgiSpacing.xs) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

// MARK: - Combined Toast Overlay

extension View {
    /// Bottom-edge stack for both toasts. One overlay (not two) so sync and
    /// model progress never cover each other.
    func combinedToastOverlay(
        sync: SyncToast.Kind?,
        model: ModelDownloadToast.Kind?,
        onModelRetry: @escaping () -> Void,
        onModelCancel: @escaping () -> Void = {},
        onModelDismiss: @escaping () -> Void = {}
    ) -> some View {
        overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let model {
                    ModelDownloadToast(
                        kind: model,
                        onCancel: onModelCancel,
                        onRetry: onModelRetry,
                        onDismiss: onModelDismiss
                    )
                    .transition(AmgiMotion.slide(from: .bottom))
                }
                if let sync {
                    SyncToast(kind: sync)
                        .transition(AmgiMotion.slide(from: .bottom))
                }
            }
            .padding(.horizontal, AmgiSpacing.md)
        }
        // Either success is worth a haptic (mirrors `syncToastOverlay`).
        // Progress updates are not — they'd fire repeatedly.
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
        let syncKey: String
        switch sync {
        case nil: syncKey = "none"
        case .progress: syncKey = "progress"
        case .success: syncKey = "success"
        }

        let modelKey: String
        switch model {
        case nil: modelKey = "none"
        case .progress: modelKey = "progress"
        case .success: modelKey = "success"
        case .failure: modelKey = "failure"
        }

        return "\(syncKey)|\(modelKey)"
    }
}
