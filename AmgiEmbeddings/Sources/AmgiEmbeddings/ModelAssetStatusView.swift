public import SwiftUI

/// Explicit per-module download consent and native MLX install progress.
public struct ModelAssetStatusView: View {
    @State private var status: ModelAssetManager.Status = .unknown
    @State private var installedBytes: Int64?
    @State private var requestedModule: ModelAssetManager.Module?
    @State private var lastModule: ModelAssetManager.Module = .text

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        LabeledContent("EmbeddingGemma 2") {
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
                Button("Retry") { requestedModule = lastModule }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        ForEach(ModelAssetManager.Module.allCases, id: \.self) { module in
            HStack {
                Text(module == .text ? "Text retrieval · Q8" : module == .vision ? "Image and video retrieval · Q8" : "Audio retrieval · BF16")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if ModelAssetManager.isInstalled(module) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Download") { requestedModule = module }.buttonStyle(.bordered).controlSize(.small).disabled(isBusy) }
            }
        }
        if case .failed(let message) = status { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .confirmationDialog("Download retrieval module?", isPresented: Binding(get: { requestedModule != nil }, set: { if !$0 { requestedModule = nil } }), titleVisibility: .visible) {
            if let requestedModule {
                Button("Download \(ByteCountFormatter.string(fromByteCount: ModelAssetManager.downloadSize(for: requestedModule), countStyle: .file))") {
                    let module = requestedModule; lastModule = module; self.requestedModule = nil
                    Task { await ModelAssetManager.shared.install(module, allowExpensiveNetwork: true) }
                }
            }
            Button("Cancel", role: .cancel) { requestedModule = nil }
        } message: { Text("Downloads verified model files for private, on-device retrieval. Audio weights use BF16; text and vision weights use 8-bit quantization.") }
        .task {
            for await next in await ModelAssetManager.shared.observe() {
                status = next
                if case .ready = next {
                    installedBytes = ModelAssetManager.installedSizeBytes()
                }
            }
        }
    }

    private var isBusy: Bool {
        switch status { case .downloading, .verifying, .extracting, .compiling: true; default: false }
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
