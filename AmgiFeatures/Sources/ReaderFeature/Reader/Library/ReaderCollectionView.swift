import AmgiAppCore
import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

/// Inside one collection: the same grid as the top level, scoped to what is
/// filed here, so nested collections open the same way and drag and drop
/// works the same at every depth.
///
/// The chip under the title is where things leave: dropping onto it moves
/// them up into the parent (tapping it goes back there).
struct ReaderCollectionView: View {
    let collectionID: String
    let progress: ReaderProgressCoordinator

    @Environment(ReaderLibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var renameText: String?
    @State private var confirmingDelete = false
    @State private var repairTarget: ReaderLibraryContent.RepairTarget?

    var body: some View {
        Group {
            if let collection = library.collection(collectionID) {
                content(for: collection)
            } else {
                // Deleted from inside (or under) this screen.
                Color.clear.onAppear { dismiss() }
            }
        }
        .amgiScreenCanvas()
        .sheet(item: $repairTarget) { target in
            BookRepairSheet(
                bookID: target.id,
                title: target.title,
                repair: target.repair,
                onRetry: { await library.retryRepairAndReload(bookID: target.id) },
                onRelink: { url in try await library.relinkAndReload(bookID: target.id, to: url) },
                onDismiss: { repairTarget = nil }
            )
        }
    }

    private func content(for collection: ReaderCollection) -> some View {
        let items = library.gridItems(in: collectionID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ParentDropChip(parentID: collection.parentID) { dismiss() }
                    .padding(.horizontal, 16)

                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "books.vertical")
                    } description: {
                        Text("Drag books onto this collection in the library, or choose Move to… on any book.")
                    }
                    .padding(.top, 40)
                } else {
                    AllBooksSection(
                        title: nil,
                        items: items,
                        scope: collectionID,
                        bookForId: { library.book(for: $0) },
                        progress: progress,
                        onRepair: { id, repair in
                            let title = library.book(for: id)?.title ?? repair.title
                            repairTarget = .init(id: id, title: title, repair: repair)
                        }
                    )
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .navigationTitle(collection.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        library.createCollection(in: collectionID)
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }
                    Button {
                        renameText = collection.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Collection", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Collection actions")
            }
        }
        .alert("Rename Collection", isPresented: Binding(
            get: { renameText != nil },
            set: { if !$0 { renameText = nil } }
        )) {
            TextField("Name", text: Binding(get: { renameText ?? "" }, set: { renameText = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renameText { library.renameCollection(collectionID, to: renameText) }
            }
        }
        .confirmationDialog(
            "Delete “\(collection.name)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) {
                library.deleteCollection(collectionID)
                dismiss()
            }
        } message: {
            Text("Its books and collections move up a level. Nothing is removed from your library.")
        }
    }
}

/// "‹ Library" (or the parent collection's name): goes back when tapped, and
/// takes anything dropped on it out of this collection into that parent.
private struct ParentDropChip: View {
    let parentID: String?
    let onTap: () -> Void

    @Environment(ReaderLibraryModel.self) private var library
    @Environment(\.palette) private var palette
    @State private var isTargeted = false

    var body: some View {
        Button(action: onTap) {
            Label {
                Text(isTargeted ? L10n.format("Move to %@", [parentName]) : parentName)
                    .lineLimit(1)
            } icon: {
                Image(systemName: isTargeted ? "arrow.up.left.circle.fill" : "arrow.turn.left.up")
            }
            .font(.system(size: 13, weight: isTargeted ? .semibold : .medium))
            .foregroundStyle(isTargeted ? palette.accent : palette.textSecondary)
            // A quiet breadcrumb until something is dragged over it; only
            // then does it become a target-looking pill.
            .padding(.horizontal, isTargeted ? 12 : 0)
            .padding(.vertical, 7)
            .background(Capsule().fill(isTargeted ? palette.accentSoft : .clear))
            .overlay {
                Capsule()
                    .strokeBorder(palette.accent, lineWidth: 1.5)
                    .opacity(isTargeted ? 1 : 0)
            }
            .scaleEffect(isTargeted ? 1.06 : 1, anchor: .leading)
            .animation(AmgiMotion.quick, value: isTargeted)
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { strings, _ in
            let refs = strings.compactMap(ReaderLibraryItemRef.init(dragString:))
            guard !refs.isEmpty else { return false }
            return library.move(refs, to: parentID)
        } isTargeted: { isTargeted = $0 }
        .accessibilityHint("Drop books here to move them out of this collection.")
    }

    private var parentName: String {
        parentID.flatMap { library.collection($0)?.name } ?? L10n.text("Library")
    }
}
