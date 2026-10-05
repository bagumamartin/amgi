import AmgiTheme
import AmgiUI
import PDFKit
import SwiftUI

#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// A compact, whole-document map of representative pages.
///
/// The strip represents the complete PDF in the available width. It does not
/// make the user scroll through thousands of pages to reach the end. A raised
/// thumbnail tracks the exact current page, including pages that are between
/// two of the representative samples.
struct PDFThumbnailScrubber: View {
    let model: PDFReaderModel
    let pageCount: Int
    let currentPage: Int
    let onSeek: (Int) -> Void
    var onInteractionChanged: (Bool) -> Void = { _ in }

    @Environment(\.palette) private var palette
    @State private var sampleImages: [Int: PlatformImage] = [:]
    @State private var sampleDocumentID: UUID?
    @State private var currentPageImage: PlatformImage?
    @State private var isScrubbing = false
    @State private var startingPage: Int?
    @State private var lastRequestedPage: Int?

    private let trackInset: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let sampleIndices = Self.sampledPageIndices(
                pageCount: pageCount,
                availableWidth: geometry.size.width - trackInset * 2
            )
            let safeCurrentPage = max(0, min(currentPage, max(0, pageCount - 1)))
            let x = selectedCenter(
                pageIndex: safeCurrentPage,
                in: geometry.size.width
            )

            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(sampleIndices, id: \.self) { index in
                        sampleTile(at: index)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, trackInset)

                currentPageTile(at: safeCurrentPage)
                    .position(x: x, y: geometry.size.height / 2)
                    .accessibilityHidden(true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Capsule())
            .gesture(scrubGesture(width: geometry.size.width))
            .amgiMaterial(.regular, in: Capsule(), interactive: true)
            .amgiMaterialElevation(Capsule())
            .scaleEffect(x: isScrubbing ? 1.025 : 1, y: isScrubbing ? 1.06 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isScrubbing)
            .task(id: Self.sampleTaskKey(documentID: model.documentID, indices: sampleIndices)) {
                if sampleDocumentID != model.documentID {
                    sampleDocumentID = model.documentID
                    sampleImages.removeAll()
                    currentPageImage = nil
                }
                await loadSamples(sampleIndices, prioritizing: safeCurrentPage)
            }
            .task(id: "\(model.documentID)-\(safeCurrentPage)") {
                await loadCurrentPageThumbnail(safeCurrentPage)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PDF pages")
        .accessibilityValue("Page \(currentPage + 1) of \(max(1, pageCount))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(max(0, pageCount - 1), currentPage + 1))
            case .decrement: onSeek(max(0, currentPage - 1))
            @unknown default: break
            }
        }
        .onDisappear {
            if isScrubbing {
                isScrubbing = false
                onInteractionChanged(false)
            }
        }
    }

    private func sampleTile(at index: Int) -> some View {
        Group {
            if let image = sampleImages[index] {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(palette.separator.opacity(0.65), lineWidth: 0.5)
                    }
            }
        }
        .frame(width: tileWidth, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(palette.separator.opacity(0.8), lineWidth: 0.5)
        }
    }

    private var tileWidth: CGFloat { 19 }

    private func currentPageTile(at index: Int) -> some View {
        let height: CGFloat = isScrubbing ? 45 : 36
        let width: CGFloat = isScrubbing ? 35 : 28

        return Group {
            if let currentPageImage {
                Image(platformImage: currentPageImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else if let sampleImage = sampleImages[index] {
                Image(platformImage: sampleImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .overlay {
                        ProgressView()
                            .controlSize(.mini)
                    }
            }
        }
        .frame(width: width, height: height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(palette.textPrimary.opacity(0.28), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
        .scaleEffect(isScrubbing ? 1.06 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isScrubbing)
        .accessibilityLabel("Selected page \(index + 1)")
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    startingPage = currentPage
                    onInteractionChanged(true)
                }
                selectPage(at: value.location.x, width: width)
            }
            .onEnded { value in
                selectPage(at: value.location.x, width: width)
                if startingPage != lastRequestedPage {
                    triggerSelectionFeedback()
                }
                isScrubbing = false
                startingPage = nil
                lastRequestedPage = nil
                onInteractionChanged(false)
            }
    }

    private func selectPage(at localX: CGFloat, width: CGFloat) {
        guard pageCount > 0 else { return }
        let usableWidth = max(1, width - trackInset * 2)
        let fraction = min(max((localX - trackInset) / usableWidth, 0), 1)
        let target = Int((fraction * CGFloat(max(0, pageCount - 1))).rounded())
        guard target != lastRequestedPage else { return }
        lastRequestedPage = target
        onSeek(target)
    }

    private func triggerSelectionFeedback() {
        #if canImport(UIKit) && !os(macOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    private func selectedCenter(pageIndex: Int, in width: CGFloat) -> CGFloat {
        guard pageCount > 1 else { return width / 2 }
        let fraction = CGFloat(pageIndex) / CGFloat(pageCount - 1)
        return trackInset + fraction * (width - trackInset * 2)
    }

    private func loadSamples(_ indices: [Int], prioritizing currentPage: Int) async {
        let ordered = [currentPage] + indices.filter { $0 != currentPage }
        for index in ordered where index >= 0 && index < pageCount {
            guard !Task.isCancelled else { return }
            if sampleImages[index] == nil,
               let image = model.thumbnail(forPage: index, size: CGSize(width: 38, height: 54)) {
                sampleImages[index] = image
            }
            // Give PDFView a chance to keep drawing the main page between the
            // small, bounded batch of overview thumbnails.
            await Task.yield()
        }
    }

    private func loadCurrentPageThumbnail(_ index: Int) async {
        currentPageImage = nil
        guard index >= 0, index < pageCount else { return }
        do {
            // Adjacent page swipes still update the page badge and exact-page
            // preview together. During a fast scrub, render only the latest
            // settled frame instead of blocking every touch sample on PDFKit.
            try await Task.sleep(for: .milliseconds(isScrubbing ? 65 : 0))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        currentPageImage = model.thumbnail(forPage: index, size: CGSize(width: 76, height: 108))
    }

    private static func sampleTaskKey(documentID: UUID, indices: [Int]) -> String {
        "\(documentID)-\(indices.map(String.init).joined(separator: ","))"
    }

    private static func sampledPageIndices(pageCount: Int, availableWidth: CGFloat) -> [Int] {
        guard pageCount > 0 else { return [] }
        let desiredCount = max(1, min(80, Int(availableWidth / 22)))
        let sampleCount = min(pageCount, desiredCount)
        guard sampleCount > 1 else { return [0] }
        return (0..<sampleCount).map { sample in
            Int((Double(sample) * Double(pageCount - 1) / Double(sampleCount - 1)).rounded())
        }
    }
}
