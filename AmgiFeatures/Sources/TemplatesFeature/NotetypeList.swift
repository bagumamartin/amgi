import SwiftUI
import AmgiTheme
import AnkiKit

/// List of notetypes with a row action menu, context menu, keyboard delete
/// command, and the familiar swipe actions. The menu is especially important
/// on Mac and iPad, where a pointer user should not have to discover a
/// horizontal swipe gesture.
struct NotetypeList: View {
    let entries: [NotetypeNameId]
    let onSelect: (NotetypeNameId) -> Void
    let onRequestDelete: (NotetypeNameId) -> Void
    let onRequestRename: (NotetypeNameId) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        List(entries, id: \.id) { entry in
            NotetypeRow(
                entry: entry,
                onTap: { onSelect(entry) },
                onDelete: { onRequestDelete(entry) },
                onRename: { onRequestRename(entry) }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { onRequestDelete(entry) } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { onRequestRename(entry) } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(palette.accent)
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .listStyle(.plain)
    }
}

struct NotetypeRow: View {
    let entry: NotetypeNameId
    let onTap: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
                        Text(entry.name)
                            .amgiFont(.body)
                            .foregroundStyle(palette.textPrimary)
                        Text(verbatim: "ID: \(entry.id)")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
            .accessibilityHint("Opens the template editor")

            Menu {
                Button {
                    onRename()
                } label: {
                    Label("Rename Notetype", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Notetype", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(entry.name)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label("Rename Notetype", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Notetype", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Rename notetype", onRename)
        .accessibilityAction(named: "Delete notetype", onDelete)
        #if os(macOS)
        .onDeleteCommand {
            onDelete()
        }
        #endif
    }
}

struct DeckTemplateListAlerts: ViewModifier {
    @Binding var showRenamePrompt: Bool
    @Binding var renameText: String
    let renameTargetName: String
    let onRename: () -> Void

    @Binding var showDeleteConfirm: Bool
    let deleteTargetName: String?
    let onDelete: () -> Void

    @Binding var showActionError: Bool
    let actionError: String?

    func body(content: Content) -> some View {
        content
            .alert("Rename notetype", isPresented: $showRenamePrompt) {
                TextField("New name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { onRename() }
            } message: {
                Text(renameTargetName)
            }
            .alert("Delete notetype", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let name = deleteTargetName {
                    Text("Delete \"\(name)\"? Cards using this notetype will be removed too.")
                }
            }
            .alert("Error", isPresented: $showActionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "An unknown error occurred.")
            }
    }
}
