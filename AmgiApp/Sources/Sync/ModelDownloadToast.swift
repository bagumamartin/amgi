// AmgiApp/Sources/Sync/ModelDownloadToast.swift
import SwiftUI
import AmgiTheme

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
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .amgiChromeShadow(Capsule(), radius: 8, y: 2, opacity: 0.12)
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
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let sync {
                    SyncToast(kind: sync)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy, value: syncToastIdentity(sync: sync, model: model))
    }

    private func syncToastIdentity(
        sync: SyncToast.Kind?,
        model: ModelDownloadToast.Kind?
    ) -> String {
        "\(String(describing: sync))|\(String(describing: model))"
    }
}
