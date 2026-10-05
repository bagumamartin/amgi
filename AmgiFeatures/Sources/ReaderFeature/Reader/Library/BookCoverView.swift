import AmgiTheme
import AmgiUI
import SwiftUI

struct BookCoverView: View {
    let coverArt: CoverArtSource
    let title: String
    let surname: String?
    let seed: String

    var body: some View {
        switch coverArt {
        case .epub(let url):
            ReaderCoverImage(fileURL: url, format: .epub) {
                BookCoverPlaceholder(title: title, surname: surname, seed: seed)
            }
        case .epubFirstPage(let source):
            // No embedded cover: render the first page, which usually *is*
            // the cover. The badge still reads EPUB. The cell's own clip +
            // hairline shapes the snapshot exactly like a real cover.
            ReaderCoverImage(fileURL: nil, format: .epub) {
                EPUBFirstPageThumbnail(source: source) {
                    BookCoverPlaceholder(title: title, surname: surname, seed: seed)
                }
            }
        case .pdf(let coverURL, let documentURL):
            // The stored cover wins when present; otherwise the PDF's first
            // page doubles as the cover so a book without embedded art still
            // shows something recognisable instead of a generic tile.
            ReaderCoverImage(fileURL: coverURL, format: .pdf) {
                PDFCoverThumbnail(documentURL: documentURL) {
                    BookCoverPlaceholder(title: title, surname: surname, seed: seed)
                }
            }
        case .anki(let path):
            ReaderCoverImage(path: path) {
                BookCoverPlaceholder(title: title, surname: surname, seed: seed)
            }
        case .none:
            BookCoverPlaceholder(title: title, surname: surname, seed: seed)
        }
    }
}

#if DEBUG

#Preview("Placeholder fallback") {
    BookCoverView(
        coverArt: .none,
        title: "어린 왕자",
        surname: "Saint-Exupéry",
        seed: "book-id-001"
    )
    .frame(width: 140, height: 190)
    .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.control))
    .padding()
}
#endif
