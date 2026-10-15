import AmgiReader
import SwiftUI

/// The prompts a library item's menu can open: Move to…, Rename, Remove a
/// book, Delete a collection. Each surface that shows library items (the
/// grid at any depth, the Continue row) keeps one of these and attaches
/// `libraryPrompts`, so a menu item behaves the same wherever it is.
struct LibraryPrompts {
    var move: MoveTarget?
    var rename: RenameTarget?
    var removeBook: RemoveTarget?
    var deleteCollection: ReaderCollection?
}

struct RenameTarget: Identifiable {
    enum Kind { case book, collection }
    let id: String
    var name: String
    let kind: Kind
}

struct RemoveTarget: Identifiable {
    let id: String
    let title: String
}

struct MoveTarget: Identifiable {
    let ref: ReaderLibraryItemRef
    var id: String { ref.dragString }
}

extension View {
    func libraryPrompts(_ prompts: Binding<LibraryPrompts>, library: ReaderLibraryModel?) -> some View {
        modifier(LibraryPromptsModifier(prompts: prompts, library: library))
    }
}

private struct LibraryPromptsModifier: ViewModifier {
    @Binding var prompts: LibraryPrompts
    let library: ReaderLibraryModel?

    func body(content: Content) -> some View {
        content
            .sheet(item: $prompts.move) { target in
                if let library {
                    MoveToCollectionSheet(item: target.ref)
                        .environment(library)
                }
            }
            .alert(
                prompts.rename?.kind == .book ? "Rename Book" : "Rename Collection",
                isPresented: Binding(
                    get: { prompts.rename != nil },
                    set: { if !$0 { prompts.rename = nil } }
                ),
                presenting: prompts.rename
            ) { target in
                TextField("Name", text: Binding(
                    get: { prompts.rename?.name ?? target.name },
                    set: { prompts.rename?.name = $0 }
                ))
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    guard let name = prompts.rename?.name, let library else { return }
                    switch target.kind {
                    case .collection:
                        library.renameCollection(target.id, to: name)
                    case .book:
                        Task { await library.renameBook(target.id, to: name) }
                    }
                }
            }
            .confirmationDialog(
                "Remove “\(prompts.removeBook?.title ?? "")”?",
                isPresented: Binding(
                    get: { prompts.removeBook != nil },
                    set: { if !$0 { prompts.removeBook = nil } }
                ),
                titleVisibility: .visible,
                presenting: prompts.removeBook
            ) { target in
                Button("Remove from Library", role: .destructive) {
                    Task { await library?.removeBook(target.id) }
                }
            } message: { _ in
                Text("It leaves this device's library. Its file stays in iCloud Drive, and your place in it is kept if you add it again.")
            }
            .confirmationDialog(
                "Delete “\(prompts.deleteCollection?.name ?? "")”?",
                isPresented: Binding(
                    get: { prompts.deleteCollection != nil },
                    set: { if !$0 { prompts.deleteCollection = nil } }
                ),
                titleVisibility: .visible,
                presenting: prompts.deleteCollection
            ) { collection in
                Button("Delete Collection", role: .destructive) {
                    library?.deleteCollection(collection.id)
                }
            } message: { _ in
                Text("Its books and collections move up a level. Nothing is removed from your library.")
            }
    }
}

extension ReaderLibraryModel {
    /// A book's menu actions, wired to `prompts` for the ones that ask
    /// first. `inContinue` adds "Remove from Continue".
    func bookMenuActions(
        bookID: String,
        title: String,
        prompts: Binding<LibraryPrompts>,
        inContinue: Bool = false
    ) -> BookMenuActions {
        let book = book(for: bookID)
        let isFile = isManagedFile(bookID)
        return BookMenuActions(
            shareFile: book.flatMap(BookShareFile.init(book:)),
            isFinished: isFinished(bookID),
            hasStarted: hasStarted(bookID),
            onAddToCollection: { prompts.wrappedValue.move = MoveTarget(ref: .book(bookID)) },
            onSetFinished: book == nil ? nil : { [weak self] in self?.setFinished(bookID, $0) },
            onRename: isFile
                ? { prompts.wrappedValue.rename = RenameTarget(id: bookID, name: title, kind: .book) }
                : nil,
            onRemoveFromContinue: inContinue ? { [weak self] in self?.removeFromContinue(bookID) } : nil,
            onRemove: isFile
                ? { prompts.wrappedValue.removeBook = RemoveTarget(id: bookID, title: title) }
                : nil
        )
    }
}

/// A book's menu, the same on long press and behind "…" in the grid and on
/// Continue cards, grouped the way Apple Books groups its own: share;
/// organise and progress; details and rename; then the removals.
struct BookMenuContent: View {
    let book: ReaderBook?
    let progress: ReaderProgressCoordinator
    var repair: ReaderBookRepair? = nil
    var onRepair: (() -> Void)? = nil
    let actions: BookMenuActions?

    var body: some View {
        if repair != nil, let onRepair {
            Button(action: onRepair) {
                Label("Repair Book…", systemImage: "wrench.and.screwdriver")
            }
        }
        if let file = actions?.shareFile {
            ShareLink(item: file, preview: SharePreview(file.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Section {
            if let onAddToCollection = actions?.onAddToCollection {
                Button(action: onAddToCollection) {
                    Label("Add to Collection…", systemImage: "text.badge.plus")
                }
            }
            if let actions, let setFinished = actions.onSetFinished, repair == nil {
                if actions.isFinished {
                    Button { setFinished(false) } label: {
                        Label("Mark as Unread", systemImage: "arrow.counterclockwise.circle")
                    }
                } else {
                    Button { setFinished(true) } label: {
                        Label("Mark as Finished", systemImage: "checkmark.circle")
                    }
                    if actions.hasStarted {
                        Button { setFinished(false) } label: {
                            Label("Mark as Unread", systemImage: "arrow.counterclockwise.circle")
                        }
                    }
                }
            }
        }
        Section {
            if let book {
                NavigationLink {
                    ReaderBookDetailView(book: book, progress: progress)
                } label: {
                    Label("Book Details & Chapters", systemImage: "info.circle")
                }
            }
            if let onRename = actions?.onRename {
                Button(action: onRename) {
                    Label("Rename…", systemImage: "character.cursor.ibeam")
                }
            }
        }
        if actions?.onRemoveFromContinue != nil || actions?.onRemove != nil {
            Section {
                if let onRemoveFromContinue = actions?.onRemoveFromContinue {
                    Button(action: onRemoveFromContinue) {
                        Label("Remove from Continue", systemImage: "minus.circle")
                    }
                }
                if let onRemove = actions?.onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove…", systemImage: "trash")
                    }
                }
            }
        }
    }
}
