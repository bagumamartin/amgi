import AmgiReader
import AmgiTheme
import SwiftUI

struct AllBooksSection: View {
    let items: [BookCellItem]
    let bookForId: (String) -> ReaderBook?
    let progress: ReaderProgressCoordinator
    let onSelectBook: ((String) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 18, alignment: .top)
    ]

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
                    if let book = bookForId(item.id) {
                        if let onSelectBook {
                            Button {
                                onSelectBook(item.id)
                            } label: {
                                AllBooksCell(item: item)
                            }
                            .buttonStyle(.pressScale)
                            #if os(iOS)
                            .matchedTransitionSource(id: item.id, in: coverTransition)
                            #endif
                        } else {
                            NavigationLink {
                                ReaderBookDetailView(book: book, progress: progress)
                                    #if os(iOS)
                                    .navigationTransition(.zoom(sourceID: item.id, in: coverTransition))
                                    #endif
                            } label: {
                                AllBooksCell(item: item)
                            }
                            .buttonStyle(.pressScale)
                            #if os(iOS)
                            .matchedTransitionSource(id: item.id, in: coverTransition)
                            #endif
                        }
                    } else {
                        AllBooksCell(item: item)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
