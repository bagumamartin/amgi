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

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 14, alignment: .top),
        count: 3
    )

    @Environment(\.palette) private var palette
    /// Anchors each book's detail push to the cover the user tapped, so the
    /// screen grows out of that cover instead of cutting in from the edge.
    @Namespace private var coverTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALL BOOKS")
                .amgiFont(.captionBold)
                .tracking(1.4)
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { item in
                    if let repair = item.repair, let onRepair {
                        // A book that needs repair must not navigate into the
                        // reader: there is nothing readable behind it. Offer
                        // the repair sheet instead of opening a blank page.
                        Button {
                            onRepair(item.id, repair)
                        } label: {
                            AllBooksCell(item: item)
                        }
                        .buttonStyle(.pressScale)
                    } else if let book = bookForId(item.id) {
                        NavigationLink {
                            ReaderOpenView(book: book, progress: progress)
                                #if os(iOS)
                                .navigationTransition(.zoom(sourceID: item.id, in: coverTransition))
                                #endif
                        } label: {
                            AllBooksCell(item: item)
                                .contextMenu {
                                    NavigationLink {
                                        ReaderBookDetailView(book: book, progress: progress)
                                    } label: {
                                        Label("Book Details & Chapters", systemImage: "info.circle")
                                    }
                                }
                        }
                        .buttonStyle(.pressScale)
                        #if os(iOS)
                        .matchedTransitionSource(id: item.id, in: coverTransition)
                        #endif
                    } else {
                        AllBooksCell(item: item)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
