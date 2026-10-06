import AmgiTheme
import AmgiUI
import SwiftUI

struct BookCoverView: View {
    let coverArt: CoverArtSource
    let title: String
    let surname: String?
    let seed: String
    var showsFormatBadge: Bool = false

    var body: some View {
        switch coverArt {
        case .epub(let url):
            ReaderCoverImage(fileURL: url, format: showsFormatBadge ? .epub : nil) {
                placeholder
            }
        case .epubFirstPage(let source):
            // No embedded cover: render the first page, which usually *is*
            // the cover. The badge still reads EPUB if format badge is enabled.
            ReaderCoverImage(fileURL: nil, format: showsFormatBadge ? .epub : nil) {
                EPUBFirstPageThumbnail(source: source) {
                    placeholder
                }
            }
        case .pdf(let coverURL, let documentURL):
            // The stored cover wins when present; otherwise the PDF's first
            // page doubles as the cover so a book without embedded art still
            // shows something recognisable instead of a generic tile.
            ReaderCoverImage(fileURL: coverURL, format: showsFormatBadge ? .pdf : nil) {
                PDFCoverThumbnail(documentURL: documentURL) {
                    placeholder
                }
            }
        case .anki(let path):
            ReaderCoverImage(path: path) {
                placeholder
            }
        case .none:
            placeholder
        }
    }

    private var placeholder: some View {
        BookCoverPlaceholder(title: title, surname: surname, seed: seed)
            .aspectRatio(1 / 1.45, contentMode: .fit)
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
