import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

struct ContinueReadingSection: View {
    let items: [ContinueReadingItem]
    let bookForId: (String) -> ReaderBook?
    let progress: ReaderProgressCoordinator

    @Environment(\.palette) private var palette
    @Environment(ReaderLibraryModel.self) private var library: ReaderLibraryModel?
    @State private var prompts = LibraryPrompts()
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
                                        .contextMenu { menu(for: item, book: book) }
                                }
                                .buttonStyle(.pressScale)
                                #if os(iOS)
                                .matchedTransitionSource(id: item.id, in: coverTransition)
                                #endif
                                .overlay(alignment: .trailing) {
                                    Menu { menu(for: item, book: book) } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(CoverTint.primaryText)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    #if os(macOS)
                                    // A Mac `Menu` is a bordered pop-up button with a chevron by
                                    // default; these are the same bare "…" as on iPhone and iPad.
                                    .menuStyle(.button)
                                    .buttonStyle(.plain)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    #endif
                                    .padding(.trailing, 6)
                                    .accessibilityLabel("Book actions")
                                }
                            } else {
                                ContinueReadingCard(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .libraryPrompts($prompts, library: library)
        }
    }

    /// The grid's book menu, plus "Remove from Continue".
    private func menu(for item: ContinueReadingItem, book: ReaderBook) -> some View {
        BookMenuContent(
            book: book,
            progress: progress,
            actions: library?.bookMenuActions(
                bookID: item.id,
                title: item.title,
                prompts: $prompts,
                inContinue: true
            )
        )
    }

    private var sectionHeader: some View {
        Text("Continue")
            .font(.system(size: 20, weight: .bold, design: .serif))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 16)
    }
}
