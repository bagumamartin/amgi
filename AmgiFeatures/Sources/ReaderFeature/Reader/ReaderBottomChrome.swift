import AmgiTheme
import AmgiUI
import SwiftUI

/// Apple Books-style bottom chrome bar.
///
/// Combines the interactive page scrubber with the Reading Style (`Aa`) menu button.
struct ReaderBottomChrome: View {
    let currentPage: Int
    let pageCount: Int
    let pageLabel: String?
    var pagesRemainingText: String? = nil
    let onSeek: (Int) -> Void
    let onOpenStyle: () -> Void

    @Environment(\.palette) private var palette

    init(
        currentPage: Int,
        pageCount: Int,
        pageLabel: String? = nil,
        pagesRemainingText: String? = nil,
        onSeek: @escaping (Int) -> Void,
        onOpenStyle: @escaping () -> Void
    ) {
        self.currentPage = currentPage
        self.pageCount = pageCount
        self.pageLabel = pageLabel
        self.pagesRemainingText = pagesRemainingText
        self.onSeek = onSeek
        self.onOpenStyle = onOpenStyle
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Interactive Scrubber
            ReaderBottomScrubber(
                currentPage: currentPage,
                pageCount: pageCount,
                pageLabel: pageLabel,
                pagesRemainingText: pagesRemainingText,
                onSeek: onSeek
            )

            // Reading Style (Aa) Button
            Button(action: onOpenStyle) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .amgiMaterial(.regular, in: Circle(), interactive: true)
                    .amgiMaterialElevation(Circle())
            }
            .accessibilityLabel("Reading Style and Themes")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
