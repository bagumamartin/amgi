import AmgiAppCore
import AmgiReader
import AmgiTheme
import SwiftUI

/// "Move to…" for a book or collection: the whole folder tree, indented, with
/// the item's current place checked and impossible destinations (a collection
/// into itself or below itself) disabled. The keyboard-and-pointer
/// counterpart to dragging, and the only way to move something into a
/// collection that is not on screen.
struct MoveToCollectionSheet: View {
    let item: ReaderLibraryItemRef

    @Environment(ReaderLibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            List {
                destinationRow(name: L10n.text("Read"), id: nil, depth: 0, systemImage: "books.vertical")
                ForEach(flattened(under: nil, depth: 1), id: \.collection.id) { entry in
                    destinationRow(
                        name: entry.collection.name,
                        id: entry.collection.id,
                        depth: entry.depth,
                        systemImage: "folder"
                    )
                }
                Section {
                    Button {
                        let id = library.createCollection(in: library.collections.parent(of: item))
                        library.move([item], to: id)
                        dismiss()
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle("Move to")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func destinationRow(name: String, id: String?, depth: Int, systemImage: String) -> some View {
        let isCurrent = library.collections.parent(of: item) == id
        let allowed = library.collections.canMove(item, to: id) && item != .collection(id ?? "")
        return Button {
            library.move([item], to: id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(allowed ? palette.accent : palette.textTertiary)
                Text(name)
                    .foregroundStyle(allowed ? palette.textPrimary : palette.textTertiary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.leading, CGFloat(max(depth - 1, 0)) * 18)
        }
        .disabled(!allowed || isCurrent)
    }

    private struct Entry {
        let collection: ReaderCollection
        let depth: Int
    }

    private func flattened(under parentID: String?, depth: Int) -> [Entry] {
        library.collections.childCollections(of: parentID)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { [Entry(collection: $0, depth: depth)] + flattened(under: $0.id, depth: depth + 1) }
    }
}
