import AmgiTheme
import AmgiUI
import SwiftUI

struct ContinueReadingCard: View {
    let item: ContinueReadingItem

    /// Wide enough to read as a featured card, narrow enough that the next
    /// card peeks in and advertises the horizontal scroll.
    private static let coverWidth: CGFloat = 196
    /// Standard trade-book ratio, shared with the grid so the two sections
    /// read as one shelf rather than two different cover shapes.
    private static let coverAspect: CGFloat = 2.0 / 3.0

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            Text(item.title)
                .amgiFont(.cardTitle)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(palette.textPrimary)
                .frame(height: 44, alignment: .topLeading)
            Text(subtitle)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(palette.accent)
        }
        .frame(width: Self.coverWidth, alignment: .leading)
    }

    private var cover: some View {
        // The format badge lives inside BookCoverView (top-trailing). The old
        // bookmark overlay sat on the same corner and covered the badge, so
        // it is gone: progress + "23% · Today" already says "in progress".
        BookCoverView(
            coverArt: item.coverArt,
            title: item.title,
            surname: item.surname,
            seed: item.id
        )
        .aspectRatio(Self.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    }

    private var subtitle: String {
        let pct = Int((item.progress * 100).rounded())
        let when = BookMetaFormatters.relativeReadingDate(item.updatedAt, locale: locale)
        return "\(pct)% · \(when)"
    }
}

#if DEBUG

#Preview {
    ContinueReadingCard(
        item: ContinueReadingItem(
            id: "preview-1",
            title: "어린 왕자",
            surname: "Saint-Exupéry",
            progress: 0.07,
            updatedAt: Date(),
            coverArt: .none
        )
    )
    .padding()
}
#endif
