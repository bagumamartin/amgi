public import SwiftUI

/// Compact download status for the e5 model (embed in Settings → Storage).
///
/// Active downloads show received/total MB with cancel; failures offer retry
/// on unmetered networks. All icon/search features degrade gracefully while
/// the model is absent, so this view is informational only — it never blocks
/// anything.
public struct ModelAssetStatusView: View {
    @State private var status: ModelAssetManager.Status = .unknown
    @State private var installedBytes: Int64?

    public init() {}

    public var body: some View {
        LabeledContent("AI model") {
            switch status {
            case .unknown, .notInstalled:
                Text("Not downloaded")
                    .foregroundStyle(.secondary)
            case .downloading(let fraction, let received, let total):
                HStack {
                    ProgressView(value: fraction) {
                        Text("\(formatMB(received)) / \(formatMB(total ?? 0))")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 160)
                    Button("Cancel") {
                        Task { await ModelAssetManager.shared.cancelDownload() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .verifying, .extracting, .compiling:
                ProgressView()
                    .controlSize(.small)
            case .ready(let version):
                Text("v\(version)\(sizeSuffix)")
                    .foregroundStyle(.secondary)
            case .failed:
                Button("Retry") {
                    Task {
                        await ModelAssetManager.shared.ensureModelAvailable(
                            allowExpensiveNetwork: true
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .task {
            for await next in await ModelAssetManager.shared.observe() {
                status = next
                if case .ready = next {
                    installedBytes = ModelAssetManager.installedSizeBytes()
                }
            }
        }
    }

    private func formatMB(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(max(0, bytes)) / 1_000_000)
    }

    private var sizeSuffix: String {
        guard let installedBytes, installedBytes > 0 else { return "" }
        let mb = Double(installedBytes) / 1_000_000
        return mb >= 1000
            ? String(format: " · %.1f GB", mb / 1000)
            : String(format: " · %.0f MB", mb)
    }
}
