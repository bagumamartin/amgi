import AmgiAppCore
import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

/// One level of the library as a grid: collections first, then books. The
/// top level and every collection screen use this same section, so the
/// layout, drag and drop, and menus behave identically at every depth.
struct AllBooksSection: View {
    /// Section heading; nil inside a collection, whose name is the screen title.
    var title: String? = L10n.text("All Books")
    let items: [LibraryGridItem]
    /// The collection this grid shows (nil: the top level). New collections
    /// made here are made inside it.
    var scope: String? = nil
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

    /// Absent in previews; without it the grid is books only, as before.
    @Environment(ReaderLibraryModel.self) private var library: ReaderLibraryModel?
    @Environment(\.palette) private var palette
    /// Anchors each book's detail push to the cover the user tapped, so the
    /// screen grows out of that cover instead of cutting in from the edge.
    @Namespace private var coverTransition

    @State private var moveTarget: MoveTarget?
    @State private var renameTarget: RenameTarget?
    @State private var deleteTarget: ReaderCollection?
    @State private var removeTarget: RemoveTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 16)
            }

            LazyVGrid(columns: columns, spacing: 24) {
                // New files land at the top level, so that is where their
                // placeholders show while they import.
                if scope == nil, let pending = library?.pendingImports {
                    ForEach(pending) { PendingImportCell(item: $0) }
                }
                ForEach(items) { item in
                    cell(for: item)
                }
            }
            .padding(.horizontal, 16)
        }
        .sheet(item: $moveTarget) { target in
            if let library {
                MoveToCollectionSheet(item: target.ref)
                    .environment(library)
            }
        }
        .alert(
            renameTarget?.kind == .book ? "Rename Book" : "Rename Collection",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            presenting: renameTarget
        ) { target in
            TextField("Name", text: Binding(
                get: { renameTarget?.name ?? target.name },
                set: { renameTarget?.name = $0 }
            ))
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let name = renameTarget?.name, let library else { return }
                switch target.kind {
                case .collection:
                    library.renameCollection(target.id, to: name)
                case .book:
                    Task { await library.renameBook(target.id, to: name) }
                }
            }
        }
        .confirmationDialog(
            "Remove “\(removeTarget?.title ?? "")”?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { target in
            Button("Remove from Library", role: .destructive) {
                Task { await library?.removeBook(target.id) }
            }
        } message: { _ in
            Text("It leaves this device's library. Its file stays in iCloud Drive, and your place in it is kept if you add it again.")
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")”?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { collection in
            Button("Delete Collection", role: .destructive) {
                library?.deleteCollection(collection.id)
            }
        } message: { _ in
            Text("Its books and collections move up a level. Nothing is removed from your library.")
        }
    }

    @ViewBuilder
    private func cell(for item: LibraryGridItem) -> some View {
        switch item {
        case .book(let book):
            AllBooksCell(
                item: book,
                book: bookForId(book.id),
                progress: progress,
                coverTransition: coverTransition,
                onRepair: onRepair,
                actions: menuActions(for: book)
            )
            .libraryDragAndDrop(
                item.ref,
                enabled: library != nil,
                onDrop: { dropped in dropOnBook(book.id, dropped) }
            ) {
                BookCoverView(coverArt: book.coverArt, title: book.title, surname: book.surname, seed: book.id)
                    .bookCoverChrome(.compact)
                    .frame(width: 90, height: 130)
            }

        case .collection(let collection):
            if let library {
                CollectionCell(
                    item: collection,
                    progress: progress,
                    coverTransition: coverTransition,
                    onRename: { renameTarget = RenameTarget(id: collection.id, name: collection.name, kind: .collection) },
                    onMove: { moveTarget = MoveTarget(ref: .collection(collection.id)) },
                    onDelete: { deleteTarget = library.collection(collection.id) }
                )
                .libraryDragAndDrop(
                    item.ref,
                    enabled: true,
                    onDrop: { dropped in library.move(dropped, to: collection.id) }
                ) {
                    CollectionCard(item: collection)
                        .frame(width: 150)
                }
            }
        }
    }

    /// Something dropped on a book: the two (or more) become a new
    /// collection, the way apps become a folder on the Home Screen. Then the
    /// name is offered for editing straight away.
    private func dropOnBook(_ bookID: String, _ dropped: [ReaderLibraryItemRef]) -> Bool {
        guard let library,
              let id = library.makeCollection(combining: .book(bookID), with: dropped) else {
            return false
        }
        renameTarget = RenameTarget(id: id, name: library.collection(id)?.name ?? "", kind: .collection)
        return true
    }

    private func menuActions(for item: BookCellItem) -> BookMenuActions? {
        guard let library else { return nil }
        let book = bookForId(item.id)
        let isFile = library.isManagedFile(item.id)
        return BookMenuActions(
            shareFile: book.flatMap(BookShareFile.init(book:)),
            isFinished: library.isFinished(item.id),
            hasStarted: library.hasStarted(item.id),
            onAddToCollection: { moveTarget = MoveTarget(ref: .book(item.id)) },
            onSetFinished: book == nil ? nil : { library.setFinished(item.id, $0) },
            onRename: isFile
                ? { renameTarget = RenameTarget(id: item.id, name: item.title, kind: .book) }
                : nil,
            onRemove: isFile ? { removeTarget = RemoveTarget(id: item.id, title: item.title) } : nil
        )
    }
}

private struct RenameTarget: Identifiable {
    enum Kind { case book, collection }
    let id: String
    var name: String
    let kind: Kind
}

private struct RemoveTarget: Identifiable {
    let id: String
    let title: String
}

private struct MoveTarget: Identifiable {
    let ref: ReaderLibraryItemRef
    var id: String { ref.dragString }
}

// MARK: - Drag and drop

extension View {
    /// Makes a grid cell draggable as `ref` and a drop target for other
    /// library items, with a lift and accent ring while something hovers.
    func libraryDragAndDrop<Preview: View>(
        _ ref: ReaderLibraryItemRef,
        enabled: Bool,
        onDrop: @escaping ([ReaderLibraryItemRef]) -> Bool,
        @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        modifier(LibraryDragAndDrop(ref: ref, enabled: enabled, onDrop: onDrop, preview: preview))
    }
}

private struct LibraryDragAndDrop<Preview: View>: ViewModifier {
    let ref: ReaderLibraryItemRef
    let enabled: Bool
    let onDrop: ([ReaderLibraryItemRef]) -> Bool
    let preview: () -> Preview

    @Environment(\.palette) private var palette
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .scaleEffect(isTargeted ? 1.05 : 1)
                .overlay {
                    RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous)
                        .strokeBorder(palette.accent, lineWidth: 2)
                        .padding(-6)
                        .opacity(isTargeted ? 1 : 0)
                }
                .animation(AmgiMotion.quick, value: isTargeted)
                .draggable(ref.dragString, preview: preview)
                .dropDestination(for: String.self) { strings, _ in
                    let refs = strings.compactMap(ReaderLibraryItemRef.init(dragString:))
                        .filter { $0 != ref }
                    guard !refs.isEmpty else { return false }
                    return onDrop(refs)
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

/// A file still importing: a placeholder cover in the book's place, with a
/// spinner, until the parsed book replaces it.
private struct PendingImportCell: View {
    let item: PendingImport

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverPlaceholder(title: item.title, surname: nil, seed: item.id.uuidString)
                .aspectRatio(1 / 1.45, contentMode: .fit)
                .overlay {
                    ZStack {
                        Rectangle().fill(palette.background.opacity(0.35))
                        ProgressView()
                    }
                }
                .bookCoverChrome()
                .frame(maxHeight: 260, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .bottom)

            Text("Importing…")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(palette.textSecondary)
                .frame(height: 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue("Importing")
    }
}

