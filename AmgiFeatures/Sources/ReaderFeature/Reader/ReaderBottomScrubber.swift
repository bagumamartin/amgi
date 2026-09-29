import AmgiTheme
import AmgiUI
import SwiftUI

/// Apple Books-style interactive bottom page scrubber.
///
/// Features:
/// - Horizontal slider track with smooth dragging.
/// - Floating badge above the scrub thumb displaying "Page X of Y" or custom label.
/// - Haptic tick feedback on page change during scrubbing.
/// - Display of current chapter / pages left in chapter.
struct ReaderBottomScrubber: View {
    let currentPage: Int
    let pageCount: Int
    let pageLabel: String
    var pagesRemainingText: String? = nil
    let onSeek: (Int) -> Void

    @Environment(\.palette) private var palette
    @State private var isDragging: Bool = false
    @State private var scrubbedPage: Int = 1
    @State private var dragOffsetFraction: CGFloat = 0

    init(
        currentPage: Int,
        pageCount: Int,
        pageLabel: String? = nil,
        pagesRemainingText: String? = nil,
        onSeek: @escaping (Int) -> Void
    ) {
        self.currentPage = max(1, currentPage)
        self.pageCount = max(1, pageCount)
        self.pageLabel = pageLabel ?? "\(self.currentPage)"
        self.pagesRemainingText = pagesRemainingText
        self.onSeek = onSeek
    }

    private var displayPage: Int {
        isDragging ? scrubbedPage : currentPage
    }

    private var progressFraction: CGFloat {
        guard pageCount > 1 else { return 0 }
        let current = CGFloat(displayPage - 1)
        let total = CGFloat(pageCount - 1)
        return min(max(current / total, 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            // Floating scrub bubble when dragging
            if isDragging {
                scrubBubble
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Track & Thumb
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(palette.separator.opacity(0.6))
                        .frame(height: 4)

                    // Filled progress track
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: max(4, width * progressFraction), height: 4)

                    // Draggable Thumb Knob
                    Circle()
                        .fill(palette.surface)
                        .overlay(Circle().stroke(palette.separator, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                        .frame(width: 20, height: 20)
                        .offset(x: max(0, min(width - 20, (width - 20) * progressFraction)))
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                scrubbedPage = currentPage
                            }
                            let usableWidth = max(width - 20, 1)
                            let fraction = min(max(value.location.x / usableWidth, 0), 1)
                            let newPage = Int(round(fraction * CGFloat(pageCount - 1))) + 1
                            if newPage != scrubbedPage {
                                #if os(iOS)
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                                #endif
                                scrubbedPage = newPage
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            onSeek(scrubbedPage)
                        }
                )
            }
            .frame(height: 20)

            // Info labels below track
            HStack {
                Text("\(pageLabel) of \(pageCount)")
                    .amgiFont(.caption, .monospacedDigits)
                    .foregroundStyle(palette.textSecondary)

                Spacer()

                if let pagesRemainingText, !pagesRemainingText.isEmpty {
                    Text(pagesRemainingText)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .amgiMaterial(.regular, in: RoundedRectangle(cornerRadius: AmgiRadius.control), interactive: true)
        .amgiMaterialElevation(RoundedRectangle(cornerRadius: AmgiRadius.control))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
    }

    private var scrubBubble: some View {
        Text("Page \(scrubbedPage)")
            .amgiFont(.captionBold, .monospacedDigits)
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .amgiMaterial(.regular, in: Capsule())
            .amgiMaterialElevation(Capsule())
    }
}
