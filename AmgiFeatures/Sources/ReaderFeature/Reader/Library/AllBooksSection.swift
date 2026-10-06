import AmgiReader
import AmgiTheme
import SwiftUI

struct AllBooksSection: View {
    let items: [BookCellItem]
    let bookForId: (String) -> ReaderBook?
    let progress: ReaderProgressCoordinator
    /// Opens the repair sheet for a book that is present but unreadable.
    /// Nil hides the affordance and every book behaves as before.
    var onRepair: ((String, ReaderBookRepair) -> Void)?

    /// Responsive column layout matching Apple Books:
    /// - iPhone: 2 columns
    /// - iPad portrait: 4 columns
    /// - iPad landscape & Mac: 6 columns
    /// With `.bottom` alignment so books of differing heights sit on a shared
    /// horizontal baseline with aligned metadata bars below.
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 20, alignment: .bottom)
    ]

    @Environment(\.palette) private var palette
    /// Anchors each book's detail push to the cover the user tapped, so the
    /// screen grows out of that cover instead of cutting in from the edge.
    @Namespace private var coverTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader

            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(items) { item in
                    AllBooksCell(
                        item: item,
                        book: bookForId(item.id),
                        progress: progress,
                        coverTransition: coverTransition,
                        onRepair: onRepair
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var sectionHeader: some View {
        Text("All Books")
            .font(.system(size: 20, weight: .bold, design: .serif))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 16)
    }
}
