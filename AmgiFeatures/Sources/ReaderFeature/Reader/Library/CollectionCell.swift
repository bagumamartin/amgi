import AmgiAppCore
import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

/// A collection in the library grid, drawn like an Apple Books *Top Picks*
/// card: a white panel with one large cover, a column of smaller ones running
/// off the trailing edge, and the collection's name beneath. It occupies one
/// grid cell, so two sit side by side on iPhone, and it shares the book
/// cells' bottom baseline and metadata bar.
struct CollectionCell: View {
    let item: CollectionCellItem
    let progress: ReaderProgressCoordinator
    let coverTransition: Namespace.ID
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    @Environment(ReaderLibraryModel.self) private var library
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                ReaderCollectionView(collectionID: item.id, progress: progress)
                    .environment(library)
                    #if os(iOS)
                    .navigationTransition(.zoom(sourceID: item.id, in: coverTransition))
                    #endif
            } label: {
                CollectionCard(item: item)
                    .contextMenu { menuItems }
            }
            .buttonStyle(.pressScale)
            #if os(iOS)
            .matchedTransitionSource(id: item.id, in: coverTransition)
            #endif

            metadataBar
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(countLabel)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRename) {
            Label("Rename", systemImage: "pencil")
        }
        Button(action: onMove) {
            Label("Move to…", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label("Delete Collection", systemImage: "trash")
        }
    }

    private var metadataBar: some View {
        // The count already sits in the card; the bar keeps only the menu,
        // so the row's metadata bars still line up across books and
        // collections.
        HStack(alignment: .center, spacing: 4) {
            Spacer(minLength: 4)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 24, height: 24)
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
        }
        .frame(height: 24)
    }

    private var countLabel: String {
        CollectionCard.countLabel(books: item.bookCount, collections: item.collectionCount)
    }
}

/// The card itself, without navigation or menus — also the drag preview.
///
/// Every collection card is the same height: the tallest a book cell can be,
/// so a row never has a book standing above a collection, and collections
/// side by side line up exactly.
struct CollectionCard: View {
    let item: CollectionCellItem

    /// Matches the book cells' height cap in `AllBooksCell`.
    static let height: CGFloat = 260

    @Environment(\.palette) private var palette

    var body: some View {
        AmgiCard(
            background: .surfaceElevated,
            shadow: palette.shadows.md,
            cornerRadius: AmgiRadius.hero,
            contentInsets: EdgeInsets()
        ) {
            VStack(alignment: .leading, spacing: 0) {
                CollectionCollage(covers: item.covers)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(Self.countLabel(books: item.bookCount, collections: item.collectionCount))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 13)
            }
        }
        .frame(height: Self.height)
    }

    static func countLabel(books: Int, collections: Int) -> String {
        var parts: [String] = []
        if books > 0 || collections == 0 {
            parts.append(books == 1 ? L10n.text("1 book") : L10n.format("%lld books", [books]))
        }
        if collections > 0 {
            parts.append(collections == 1 ? L10n.text("1 collection") : L10n.format("%lld collections", [collections]))
        }
        return parts.joined(separator: " · ")
    }
}

/// The collection's covers, each whole and in its own shape, arranged by
/// `CollectionMosaic` to fill the card. Until a cover's real proportions are
/// measured it is laid out as a standard book, then the mosaic settles.
struct CollectionCollage: View {
    let covers: [BookCellItem]

    private let gap: CGFloat = 8

    @Environment(\.palette) private var palette
    @State private var aspects: [String: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            if let arrangement = CollectionMosaic.layout(
                aspects: covers.map(aspect(of:)),
                in: geometry.size,
                gap: gap
            ) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(arrangement.frames.enumerated()), id: \.offset) { index, frame in
                        cover(at: index, size: frame.size)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: arrangement.size.width, height: arrangement.size.height, alignment: .topLeading)
                // Sits on the card's bottom edge, above the title, the way
                // Apple Books' collection art does; any spare height goes
                // above it.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                .animation(AmgiMotion.standard, value: aspects)
            } else {
                emptyCollage
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .task(id: covers.map(\.id)) {
            for book in covers.prefix(CollectionMosaic.maxCovers) where aspects[book.id] == nil {
                aspects[book.id] = await CoverAspectResolver.aspect(for: book)
            }
        }
    }

    private func aspect(of book: BookCellItem) -> CGFloat {
        aspects[book.id] ?? CoverAspectResolver.cached(book.id) ?? CoverAspectResolver.bookAspect
    }

    @ViewBuilder
    private func cover(at index: Int, size: CGSize) -> some View {
        if covers.indices.contains(index) {
            let book = covers[index]
            BookCoverView(
                coverArt: book.coverArt,
                title: book.title,
                surname: book.surname,
                seed: book.id
            )
            .bookCoverChrome(.compact)
            .frame(width: size.width, height: size.height)
        }
    }

    /// An empty collection still looks like a place for books: a dashed
    /// book-shaped outline where the first one will go.
    private var emptyCollage: some View {
        RoundedRectangle(cornerRadius: AmgiRadius.bookCover, style: .continuous)
            .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .aspectRatio(CoverAspectResolver.bookAspect, contentMode: .fit)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(.vertical, 6)
    }
}
