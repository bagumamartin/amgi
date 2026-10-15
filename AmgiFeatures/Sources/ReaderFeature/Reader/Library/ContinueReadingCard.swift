import AmgiAppCore
import AmgiTheme
import AmgiUI
import SwiftUI

/// A Continue card, built the way Apple Books builds one: the backdrop is
/// tinted from the book's own cover, the text sits on it in white, and the
/// cover keeps its shape at the leading edge with the same book chrome as
/// the grid.
struct ContinueReadingCard: View {
    let item: ContinueReadingItem

    static let menuWidth: CGFloat = 32
    private static let cardWidth: CGFloat = 280
    private static let cardHeight: CGFloat = 84
    private static let thumbWidth: CGFloat = 46
    private static let thumbHeight: CGFloat = 64

    @State private var tint: CoverTint?

    var body: some View {
        HStack(spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(CoverTint.primaryText)

                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(CoverTint.primaryText)
                        .lineLimit(1)
                }

                Text(statusLine)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(CoverTint.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Room for the "…" menu, which the section lays over this spot:
            // a menu inside the card's navigation link would open the book.
            Color.clear.frame(width: ContinueReadingCard.menuWidth)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .coverTintedCard(tint ?? CoverTintResolver.cached(bookID: item.id) ?? .neutral)
        .animation(AmgiMotion.standard, value: tint)
        .task(id: item.id) {
            tint = await CoverTintResolver.tint(bookID: item.id, coverArt: item.coverArt)
        }
    }

    private var cover: some View {
        BookCoverView(
            coverArt: item.coverArt,
            title: item.title,
            surname: item.surname,
            seed: item.id
        )
        // Same rule as the grid: dress the fitted cover, then fix the slot,
        // so a wide or squat cover is not boxed in an outline.
        .bookCoverChrome(.compact)
        // The card is always dark, whatever the app's appearance: the chrome's
        // dark-mode edge (a light hairline) is the one that separates a cover
        // from a backdrop tinted in its own colour.
        .environment(\.colorScheme, .dark)
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
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
