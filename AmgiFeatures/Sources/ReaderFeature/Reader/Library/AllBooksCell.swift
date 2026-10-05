import AmgiTheme
import AmgiReaderEPUB
import SwiftUI

struct AllBooksCell: View {
    let item: BookCellItem

    /// Matches the featured cards so both sections share one cover shape.
    private static let coverAspect: CGFloat = 2.0 / 3.0

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCoverView(
                coverArt: item.coverArt,
                title: item.title,
                surname: item.surname,
                seed: item.id
            )
            .aspectRatio(Self.coverAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if let repair = item.repair {
                    repairBadge(repair)
                }
            }

            Text(item.title)
                .amgiFont(.bodyEmphasis)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(palette.textPrimary)
                // Reserve two lines so neighbouring titles stay aligned even
                // when one wraps and the other does not.
                .frame(minHeight: 38, alignment: .topLeading)

            if let author = item.author {
                Text(author)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            } else if let repair = item.repair {
                Text(repair.title)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.repair?.title ?? "")
        .accessibilityHint(item.repair == nil ? "" : "Double tap to repair this book.")
    }

    /// Marks an unreadable book without hiding it. The label is the repair
    /// reason so VoiceOver announces the problem at the row, not just a
    /// generic "image".
    @ViewBuilder
    private func repairBadge(_ repair: ReaderBookRepair) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .amgiFont(.caption)
            .foregroundStyle(.white)
            .padding(5)
            .background(
                Circle().fill(palette.accent)
            )
            .padding(6)
            .accessibilityHidden(true)
    }
}

#if DEBUG

#Preview {
    AllBooksCell(
        item: BookCellItem(
            id: "preview-2",
            title: "Don Quijote",
            author: "Miguel de Cervantes",
            surname: "Cervantes",
            coverArt: .none,
            repair: nil
        )
    )
    .frame(width: 110)
    .padding()
}

#Preview("Needing repair") {
    AllBooksCell(
        item: BookCellItem(
            id: "preview-3",
            title: "Broken Book",
            author: nil,
            surname: nil,
            coverArt: .none,
            repair: ReaderBookRepair(
                fault: .sourceMissing,
                detail: "The stored EPUB for this book is missing on disk."
            )
        )
    )
    .frame(width: 110)
    .padding()
}
#endif
