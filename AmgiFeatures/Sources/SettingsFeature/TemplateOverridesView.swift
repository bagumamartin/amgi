import SwiftUI
import AmgiUI
import AmgiCardWeb
import AmgiTheme
import AmgiAppCore
import AnkiClients
import AnkiKit
import Dependencies
import Sharing
import AmgiReviewCore
// MemberImportVisibility: CardRenderEngine.displayName is a ReviewFeature extension.
import ReviewFeature

/// R11 per-template override list: each stored override as
/// "Notetype · Template — engine". The original List remains the layout
/// primitive, but every row now has a visible action menu, a context menu,
/// and a keyboard-accessible destructive action in addition to swipe delete.
struct TemplateOverridesView: View {
    @Shared(.appStorage(ReviewPreferences.Keys.templateRenderOverrides))
    private var overridesRaw: String = "{}"

    @Dependency(\.notetypesClient) private var notetypesClient

    @Environment(\.palette) private var palette
    @State private var displayNames: [String: String] = [:]
    @State private var pendingDelete: OverrideEntry?

    struct OverrideEntry: Identifiable {
        let key: String
        let engine: CardRenderEngine

        var id: String { key }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Overrides",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Set one from the render-mode sheet while reviewing.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(entries) { entry in
                    row(for: entry)
                        .listRowBackground(palette.surfaceElevated)
                }
                .onDelete(perform: delete)
            }
        }
        .scrollContentBackground(.hidden)
        .amgiScreenCanvas()
        .navigationTitle("Template Overrides")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: overridesRaw) { await resolveNames() }
        .alert(
            "Remove template override?",
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { entry in
            Button("Remove", role: .destructive) {
                remove(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\(displayNames[entry.key] ?? entry.key) will use the global rendering engine again.")
        }
    }

    private var entries: [OverrideEntry] {
        TemplateRenderOverrides.entries(in: overridesRaw).map {
            OverrideEntry(key: $0.key, engine: $0.engine)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    @ViewBuilder
    private func row(for entry: OverrideEntry) -> some View {
        HStack(spacing: AmgiSpacing.md) {
            SettingsIconTile(systemImage: "doc.text", tone: .neutral)
            Text(displayNames[entry.key] ?? entry.key)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: AmgiSpacing.sm)
            Text(entry.engine.displayName)
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

            Menu {
                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Label("Remove Override", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(displayNames[entry.key] ?? entry.key)")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Label("Remove Override", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Template override for \(displayNames[entry.key] ?? entry.key)")
        .accessibilityValue(entry.engine.displayName)
        .accessibilityAction(named: "Remove template override") {
            pendingDelete = entry
        }
        #if os(macOS)
        .onDeleteCommand {
            pendingDelete = entry
        }
        #endif
    }

    private func delete(at offsets: IndexSet) {
        let keys = offsets.compactMap { index in
            entries.indices.contains(index) ? entries[index].key : nil
        }
        for key in keys {
            let updated = TemplateRenderOverrides.removing(key: key, in: overridesRaw)
            $overridesRaw.withLock { $0 = updated }
        }
    }

    private func remove(_ entry: OverrideEntry) {
        let updated = TemplateRenderOverrides.removing(key: entry.key, in: overridesRaw)
        $overridesRaw.withLock { $0 = updated }
        pendingDelete = nil
    }

    private func resolveNames() async {
        var resolved: [String: String] = [:]
        var notetypes: [Int64: Notetype] = [:]
        for entry in entries {
            let parts = entry.key.split(separator: ":")
            guard parts.count == 2,
                  let mid = Int64(parts[0]),
                  let ord = Int(parts[1])
            else { continue }
            if notetypes[mid] == nil {
                notetypes[mid] = try? await notetypesClient.get(NotetypeID(mid))
            }
            guard let notetype = notetypes[mid] else { continue }
            let templateName = notetype.templates.indices.contains(ord)
                ? notetype.templates[ord].name
                : "Card \(ord + 1)"
            resolved[entry.key] = "\(notetype.name) · \(templateName)"
        }
        displayNames = resolved
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TemplateOverridesView()
    }
}
#endif
