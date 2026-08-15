import SwiftUI
import UIKit
import AmgiTheme
import AmgiUI

// MARK: - imageOcclusionPreviewHeight

@MainActor
func imageOcclusionPreviewHeight(for image: UIImage) -> CGFloat {
    let screenBounds = UIScreen.main.bounds
    let screenWidth = screenBounds.width - 32
    let ratio = image.size.height / max(image.size.width, 1)
    let idealHeight = screenWidth * ratio
    return min(max(idealHeight, 180), 260)
}

// MARK: - ImageOcclusionMaskSummaryCard

struct ImageOcclusionMaskSummaryCard: View {
    @Environment(\.palette) private var palette
    let image: UIImage
    let masks: [IOMask]
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OcclusionCanvasView(
                image: image,
                masks: .constant(masks),
                selectedMaskIndex: .constant(nil),
                shapeType: .select
            )
            .frame(height: imageOcclusionPreviewHeight(for: image))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false)

            HStack(spacing: 12) {
                Text(masks.isEmpty ? "No masks yet" : "\(masks.count) masks")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button(action: action) {
                    Text("Edit")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.pill, style: .continuous))
    }
}
