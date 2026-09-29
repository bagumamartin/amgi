import AmgiTheme
import AmgiUI
import PDFKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// In-memory cache for rendered miniature page thumbnails.
@MainActor
final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()
    private var cache = NSCache<NSNumber, PlatformImage>()

    init() {
        cache.countLimit = 150
    }

    func get(for pageIndex: Int) -> PlatformImage? {
        cache.object(forKey: NSNumber(value: pageIndex))
    }

    func set(_ image: PlatformImage, for pageIndex: Int) {
        cache.setObject(image, forKey: NSNumber(value: pageIndex))
    }
}

/// Miniature thumbnail card representing a single PDF page in the filmstrip scrubber.
struct PDFMiniThumbnailCard: View {
    let document: PDFDocument?
    let pageIndex: Int
    let isCurrent: Bool

    @State private var thumbnail: PlatformImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(platformImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.white)
            }
        }
        .frame(width: 18, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(isCurrent ? Color.primary : Color.secondary.opacity(0.3), lineWidth: isCurrent ? 1.5 : 0.5)
        )
        .scaleEffect(isCurrent ? 1.15 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isCurrent)
        .task(id: pageIndex) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let cached = PDFThumbnailCache.shared.get(for: pageIndex) {
            thumbnail = cached
            return
        }
        guard let document, let page = document.page(at: pageIndex) else { return }
        let img = page.thumbnail(of: CGSize(width: 36, height: 52), for: .cropBox)
        PDFThumbnailCache.shared.set(img, for: pageIndex)
        thumbnail = img
    }
}

/// Apple Books-style bottom thumbnail scrubber for PDFs.
/// Shows a floating frosted capsule containing miniature page thumbnails.
/// Users can swipe/scroll through the filmstrip and tap any thumbnail to jump.
struct PDFThumbnailScrubber: View {
    let document: PDFDocument?
    let pageCount: Int
    let currentPage: Int
    let onSeek: (Int) -> Void

    @Environment(\.palette) private var palette
    @State private var isInteracting: Bool = false
    @State private var lastHapticPage: Int = -1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(0..<max(1, pageCount), id: \.self) { index in
                        PDFMiniThumbnailCard(
                            document: document,
                            pageIndex: index,
                            isCurrent: index == currentPage
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            triggerHaptic()
                            onSeek(index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(height: 44)
            .onChange(of: currentPage) { _, newPage in
                if !isInteracting {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newPage, anchor: .center)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(currentPage, anchor: .center)
            }
        }
        .frame(maxWidth: min(CGFloat(pageCount * 23 + 32), 340))
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
    }

    private func triggerHaptic() {
        #if canImport(UIKit) && !os(macOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}
