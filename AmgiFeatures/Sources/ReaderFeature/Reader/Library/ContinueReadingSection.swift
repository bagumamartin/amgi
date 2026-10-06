import AmgiReader
import AmgiTheme
import SwiftUI

struct ContinueReadingSection: View {
    let items: [ContinueReadingItem]
    let bookForId: (String) -> ReaderBook?
    let progress: ReaderProgressCoordinator

    @Environment(\.palette) private var palette
    /// See `AllBooksSection` — the detail push grows from the tapped card.
    @Namespace private var coverTransition

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy: an eager HStack builds — and decodes the cover for
                    // — every book in the row before any of it is on screen.
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            if let book = bookForId(item.id) {
                                NavigationLink {
                                    ReaderOpenView(book: book, progress: progress)
                                        #if os(iOS)
                                        .navigationTransition(.zoom(sourceID: item.id, in: coverTransition))
                                        #endif
                                } label: {
                                    ContinueReadingCard(item: item)
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
                                ContinueReadingCard(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var sectionHeader: some View {
        Text("Continue")
            .font(.system(size: 20, weight: .bold, design: .serif))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 16)
    }
}
