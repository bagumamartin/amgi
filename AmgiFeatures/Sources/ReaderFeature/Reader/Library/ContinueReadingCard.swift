import AmgiAppCore
import AmgiTheme
import AmgiUI
import SwiftUI

struct ContinueReadingCard: View {
    let item: ContinueReadingItem

    private static let cardWidth: CGFloat = 280
    private static let cardHeight: CGFloat = 80
    private static let thumbWidth: CGFloat = 44
    private static let thumbHeight: CGFloat = 62

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(palette.textPrimary)

                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }

                Text(statusLine)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.surfaceElevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var cover: some View {
        BookCoverView(
            coverArt: item.coverArt,
            title: item.title,
            surname: item.surname,
            seed: item.id
        )
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }

    private var statusLine: String {
        let pct = Int((item.progress * 100).rounded())
        // "PDF" is a universal format badge; only the generic kind word is copy.
        let kind = item.formatLabel == "Book" ? L10n.text("Book") : item.formatLabel
        return "\(kind) • \(pct)%"
    }
}

#if DEBUG

#Preview {
    ContinueReadingCard(
        item: ContinueReadingItem(
            id: "preview-1",
            title: "Rang & Dale's Pharmacology",
            author: "James M. Ritter",
            surname: "Ritter",
            progress: 0.54,
            updatedAt: Date(),
            coverArt: .none,
            formatLabel: "Book"
        )
    )
    .padding()
}
#endif
