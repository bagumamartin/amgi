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
///
/// The page follows the finger live, but through two paths of different
/// weight. While the finger is down, `onScrubSeek` moves only the page view,
/// at most once per display frame and only to the latest page — never once
/// per page crossed, which made a 600-page book stutter as `PDFView` laid out
/// pages the user was already past. When the finger lifts, `onSeek` commits
/// the final page to the reader's navigation (page label, saved progress).
struct PDFThumbnailScrubber: View {
    let model: PDFReaderModel
    let pageCount: Int
    let currentPage: Int
    /// Shared with the page badge so it follows the finger on the same frame.
    let scrubState: PDFScrubState
    /// Commits a page: on release, and for VoiceOver's adjustable action.
    let onSeek: (Int) -> Void
    /// Moves the page view only, live during a scrub. Defaults to `onSeek`.
    var onScrubSeek: ((Int) -> Void)?
    var onInteractionChanged: (Bool) -> Void = { _ in }

    @Environment(\.palette) private var palette
    @State private var sampleImages: [Int: PlatformImage] = [:]
    @State private var sampleDocumentID: UUID?
    @State private var selectedImage: (page: Int, image: PlatformImage)?
    @State private var isScrubbing = false
    /// The page under the finger while scrubbing; nil otherwise.
    private var scrubPage: Int? {
        get { scrubState.page }
        nonmutating set { scrubState.page = newValue }
    }
    @State private var seeks = PDFScrubSeekCoalescer()
    @State private var haptics = PDFScrubberHaptics()

    private let trackInset: CGFloat = 12
    private let stripHeight: CGFloat = 56
    private static let sampleSize = CGSize(width: 38, height: 54)
    private static let selectedSize = CGSize(width: 76, height: 108)
    /// The selected tile at its largest — scrubbing size times its scale
    /// effect — so the clamp holds at the peak of the lift animation too.
    private static let largestTileSize = CGSize(width: 35 * 1.06, height: 45 * 1.06)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let sampleIndices = PDFScrubberGeometry.sampledPageIndices(
                pageCount: pageCount,
                availableWidth: width - trackInset * 2
            )
            let safeCurrentPage = max(0, min(currentPage, max(0, pageCount - 1)))
            let displayPage = scrubPage ?? safeCurrentPage
            let x = PDFScrubberGeometry.clampedCenterX(
                PDFScrubberGeometry.centerX(
                    forPage: displayPage,
                    width: width,
                    inset: trackInset,
                    pageCount: pageCount
                ),
                stripWidth: width,
                stripHeight: geometry.size.height,
                tileSize: Self.largestTileSize,
                margin: 2
            )

            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(sampleIndices, id: \.self) { index in
                        // The page the raised tile shows is not shown again
                        // in the strip. Near either end the raised tile is
                        // pulled inward to stay inside the capsule, which
                        // uncovered a sliver of the same page beside it.
                        sampleTile(at: index)
                            .opacity(index == displayPage ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, trackInset)

                currentPageTile(at: displayPage)
                    .position(x: x, y: geometry.size.height / 2)
                    .accessibilityHidden(true)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Capsule())
            .gesture(scrubGesture(width: width))
            .amgiMaterial(.regular, in: Capsule(), interactive: true)
            .amgiMaterialElevation(Capsule())
            .scaleEffect(x: isScrubbing ? 1.025 : 1, y: isScrubbing ? 1.06 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isScrubbing)
            .task(id: Self.sampleTaskKey(documentID: model.documentID, indices: sampleIndices)) {
                if sampleDocumentID != model.documentID {
                    sampleDocumentID = model.documentID
                    sampleImages.removeAll()
                    selectedImage = nil
                }
                await loadSamples(sampleIndices, prioritizing: safeCurrentPage)
            }
            .task(id: SelectedTaskKey(documentID: model.documentID, page: displayPage, isScrubbing: isScrubbing)) {
                await loadSelectedThumbnail(displayPage)
            }
        }
        .frame(height: stripHeight)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PDF pages")
        .accessibilityValue("Page \(scrubState.displayedPage(navigationPage: currentPage) + 1) of \(max(1, pageCount))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(max(0, pageCount - 1), currentPage + 1))
            case .decrement: onSeek(max(0, currentPage - 1))
            @unknown default: break
            }
        }
        .onDisappear {
            seeks.end()
            if isScrubbing {
                isScrubbing = false
                scrubPage = nil
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

    /// The best artwork available for `index` without drawing: the exact page
    /// if it is cached or just loaded, else the nearest overview sample, so a
    /// fast scrub shows a near-enough page rather than a spinner.
    private func selectedArtwork(for index: Int) -> PlatformImage? {
        if let cached = model.cachedThumbnail(forPage: index, size: Self.selectedSize) {
            return cached
        }
        if let selectedImage, selectedImage.page == index {
            return selectedImage.image
        }
        if let exact = sampleImages[index] { return exact }
        guard let nearest = PDFScrubberGeometry.nearestSample(to: index, in: Array(sampleImages.keys)) else {
            return nil
        }
        return sampleImages[nearest]
    }

    private func currentPageTile(at index: Int) -> some View {
        let height: CGFloat = isScrubbing ? 45 : 36
        let width: CGFloat = isScrubbing ? 35 : 28

        return Group {
            if let image = selectedArtwork(for: index) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .padding(2)
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

    // MARK: - Gesture

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    haptics.prepare()
                    seeks.begin(at: currentPage, apply: onScrubSeek ?? onSeek)
                    onInteractionChanged(true)
                }
                track(to: page(at: value.location.x, width: width))
            }
            .onEnded { value in
                let target = page(at: value.location.x, width: width)
                track(to: target)
                seeks.end()
                // Interaction ends before the commit so the page view reports
                // page changes again by the time navigation catches up.
                isScrubbing = false
                onInteractionChanged(false)
                onSeek(target)
                // `onSeek` moves the navigation synchronously, so `currentPage`
                // already reads `target` and the tile does not flick back.
                scrubPage = nil
            }
    }

    private func page(at x: CGFloat, width: CGFloat) -> Int {
        PDFScrubberGeometry.pageIndex(atX: x, width: width, inset: trackInset, pageCount: pageCount)
    }

    /// Moves the preview to `target`, ticks, and queues the live seek.
    private func track(to target: Int) {
        guard pageCount > 0, target != scrubPage else { return }
        let isFirstTouch = scrubPage == nil
        scrubPage = target
        if !isFirstTouch || target != currentPage {
            haptics.selectionChanged()
        }
        seeks.request(target)
    }

    // MARK: - Artwork

    private func loadSamples(_ indices: [Int], prioritizing currentPage: Int) async {
        let ordered = [currentPage] + indices.filter { $0 != currentPage }
        for index in ordered where index >= 0 && index < pageCount {
            guard !Task.isCancelled else { return }
            if sampleImages[index] == nil,
               let image = await model.thumbnail(forPage: index, size: Self.sampleSize) {
                sampleImages[index] = image
            }
        }
    }

    private func loadSelectedThumbnail(_ index: Int) async {
        guard index >= 0, index < pageCount else { return }
        if model.cachedThumbnail(forPage: index, size: Self.selectedSize) == nil {
            guard let image = await model.thumbnail(forPage: index, size: Self.selectedSize),
                  !Task.isCancelled else { return }
            selectedImage = (index, image)
        }
        // At rest, warm the neighbours so the next page turn or a short scrub
        // finds them drawn. Mid-scrub the finger is already elsewhere by the
        // time they would land.
        guard !isScrubbing else { return }
        await model.prefetchThumbnails(around: index, radius: 3, size: Self.selectedSize)
    }

    private static func sampleTaskKey(documentID: UUID, indices: [Int]) -> String {
        "\(documentID)-\(indices.map(String.init).joined(separator: ","))"
    }

    private struct SelectedTaskKey: Equatable {
        let documentID: UUID
        let page: Int
        let isScrubbing: Bool
    }
}

/// A selection tick per page crossed, as Apple Books gives.
///
/// A held, prepared generator rather than `.sensoryFeedback`: a fast scrub
/// crosses several pages per frame, and a generator that is re-prepared after
/// every tick keeps the Taptic Engine warm so none of them is late or dropped.
@MainActor
final class PDFScrubberHaptics {
    #if canImport(UIKit) && !os(macOS)
    private let generator = UISelectionFeedbackGenerator()
    #endif

    func prepare() {
        #if canImport(UIKit) && !os(macOS)
        generator.prepare()
        #endif
    }

    func selectionChanged() {
        #if canImport(UIKit) && !os(macOS)
        generator.selectionChanged()
        generator.prepare()
        #endif
    }
}
