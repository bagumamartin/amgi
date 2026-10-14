import AmgiAppCore
import AVKit
import PDFKit
import SwiftUI

/// Owned sources open in a native preview at the retrieved page/time. The
/// excerpt remains available when a file has been removed since indexing.
struct AssistantSourcePreview: View {
    let source: AssistantSource
    let profile: ProfileContext
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    private var ownedURL: URL? {
        guard profile.isCurrent(AccountStore.shared.selectedContext), let url = source.url, url.isFileURL else { return nil }
        let root = AccountStore.profileDirectory(for: AccountStore.shared.current.id).resolvingSymlinksInPath().path + "/"
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let url = ownedURL {
                    if url.pathExtension.lowercased() == "pdf" {
                        SourcePDF(url: url, page: page).frame(maxHeight: .infinity)
                    } else if source.modality == "audio" || source.modality == "video" {
                        VideoPlayer(player: player).frame(minHeight: 160)
                    } else if source.modality == "image" {
                        #if os(macOS)
                        if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
                        #else
                        if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit() }
                        #endif
                    }
                } else if source.url != nil {
                    Label("This source is no longer available in this profile.", systemImage: "doc.badge.ellipsis").foregroundStyle(.secondary)
                }
                if !source.anchor.isEmpty { Text(source.anchor).font(.caption).foregroundStyle(.secondary) }
                if !source.excerpt.isEmpty {
                    ScrollView { Text(source.excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .frame(maxHeight: 240)
                }
            }
            .padding()
            .navigationTitle(source.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            guard let url = ownedURL, source.modality == "audio" || source.modality == "video" else { return }
            let created = AVPlayer(url: url); player = created
            let time = source.anchor.replacingOccurrences(of: "time:", with: "").split(separator: "-").first.flatMap { Double($0) } ?? 0
            await created.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: AccountStore.shared.selectionID) { player?.pause(); dismiss() }
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 500)
        #endif
    }
    private var page: Int {
        guard source.anchor.hasPrefix("page:"), let number = source.anchor.split(separator: ":").dropFirst().first.flatMap({ Int($0) }) else { return 0 }
        return max(0, number - 1)
    }
}

#if os(macOS)
private struct SourcePDF: NSViewRepresentable {
    let url: URL; let page: Int
    func makeNSView(context: Context) -> PDFView { configure(PDFView()) }
    func updateNSView(_ view: PDFView, context: Context) {}
    private func configure(_ view: PDFView) -> PDFView {
        view.autoScales = true; view.document = PDFDocument(url: url)
        if let target = view.document?.page(at: page) { view.go(to: target) }
        return view
    }
}
#else
private struct SourcePDF: UIViewRepresentable {
    let url: URL; let page: Int
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url)
        if let target = view.document?.page(at: page) { view.go(to: target) }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#endif
