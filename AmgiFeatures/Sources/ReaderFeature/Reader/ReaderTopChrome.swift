import AmgiTheme
import AmgiUI
import SwiftUI

/// Apple Books-style floating top chrome bar.
///
/// Features:
/// - Leading: Close / Back button (dismisses reader to library).
/// - Center: Book title / chapter running head.
/// - Trailing:
///   - Bookmark toggle (`bookmark` / `bookmark.fill`)
///   - Search button (`magnifyingglass`)
///   - Contents list button (`list.bullet`)
struct ReaderTopChrome: View {
    let bookTitle: String
    var chapterTitle: String? = nil
    let isBookmarked: Bool
    let onClose: () -> Void
    let onBookmarkToggle: () -> Void
    let onSearch: () -> Void
    let onContents: () -> Void

    @Environment(\.palette) private var palette

    init(
        bookTitle: String,
        chapterTitle: String? = nil,
        isBookmarked: Bool,
        onClose: @escaping () -> Void,
        onBookmarkToggle: @escaping () -> Void,
        onSearch: @escaping () -> Void,
        onContents: @escaping () -> Void
    ) {
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        self.isBookmarked = isBookmarked
        self.onClose = onClose
        self.onBookmarkToggle = onBookmarkToggle
        self.onSearch = onSearch
        self.onContents = onContents
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 38, height: 38)
                    .amgiMaterial(.regular, in: Circle(), interactive: true)
                    .amgiMaterialElevation(Circle())
            }
            .accessibilityLabel("Close")

            Spacer(minLength: 8)

            // Running head
            VStack(spacing: 2) {
                Text(bookTitle)
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let chapterTitle, !chapterTitle.isEmpty, chapterTitle != bookTitle {
                    Text(chapterTitle)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .allowsHitTesting(false)

            Spacer(minLength: 8)

            // Trailing actions group
            HStack(spacing: 8) {
                // In-document Search
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 38, height: 38)
                        .amgiMaterial(.regular, in: Circle(), interactive: true)
                        .amgiMaterialElevation(Circle())
                }
                .accessibilityLabel("Search book")

                // Bookmark toggle
                Button {
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    #endif
                    onBookmarkToggle()
                } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isBookmarked ? palette.accent : palette.textPrimary)
                        .frame(width: 38, height: 38)
                        .amgiMaterial(.regular, in: Circle(), interactive: true)
                        .amgiMaterialElevation(Circle())
                }
                .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Add Bookmark")

                // Contents / Outline
                Button(action: onContents) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 38, height: 38)
                        .amgiMaterial(.regular, in: Circle(), interactive: true)
                        .amgiMaterialElevation(Circle())
                }
                .accessibilityLabel("Table of Contents")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
