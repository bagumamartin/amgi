import SwiftUI
import Combine
import Foundation
import AmgiUI
import AnkiBackend
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import AmgiTheme

// MARK: - Remove Tags

struct RemoveTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let allTags: [String]
    let onRemove: (String) async -> Void

    @State private var query = ""
    @State private var working = false

    private var filtered: [String] {
        query.isEmpty ? allTags : allTags.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { tag in
                Button {
                    Task {
                        working = true
                        await onRemove(tag)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Image(systemName: "tag.slash").foregroundStyle(palette.textSecondary)
                        Text(tag).foregroundStyle(palette.textPrimary)
                    }
                }
                .disabled(working)
            }
            .searchable(text: $query, prompt: "Filter tags")
            .navigationTitle("Remove Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Forget

struct ForgetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let onApply: (_ restorePosition: Bool, _ resetCounts: Bool) -> Void

    @AppStorage("browse.forget.restorePosition") private var restorePosition = false
    @AppStorage("browse.forget.resetCounts") private var resetCounts = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Restore original position", isOn: $restorePosition)
                    Toggle("Reset repetition and lapse counts", isOn: $resetCounts)
                } footer: {
                    Text("Desktop Forget options. Unchecked restores cards to the end of the new queue without clearing counts.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .navigationTitle("Forget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Forget") {
                        onApply(restorePosition, resetCounts)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Copy Note

struct CopyNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let noteIDs: [NoteID]
    let cardIDs: [CardID]
    var model: BrowseModel

    @State private var status: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(copyDescription)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textSecondary)
                }
                if let status {
                    Section {
                        Text(status).foregroundStyle(palette.positive)
                    }
                }
                Section {
                    Button {
                        Task { await copy() }
                    } label: {
                        Label("Open Copy in Add Note", systemImage: "doc.on.doc")
                    }
                    .disabled(working || effectiveNoteID == nil)
                }
            }
            .navigationTitle("Create Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var effectiveNoteID: NoteID? {
        noteIDs.first
    }

    private var copyDescription: String {
        if noteIDs.count == 1 {
            return "Copies the selected note's fields and tags into a prefilled Add Note form."
        } else if !cardIDs.isEmpty {
            return "Copies the first selected card's note into a prefilled Add Note form."
        }
        return "Select a single note (or card) to copy it."
    }

    private func copy() async {
        let nid: NoteID?
        if let first = noteIDs.first {
            nid = first
        } else if let firstCard = cardIDs.first {
            nid = await model.noteIDsOfCards([firstCard]).first
        } else {
            nid = nil
        }
        guard let nid else { return }
        working = true
        defer { working = false }
        if let template = await model.copyTemplate(of: nid) {
            BrowseCopyHandoff.shared.template = template
            status = "Copy ready — open Add Note to edit it."
        } else {
            status = "Couldn't load that note."
        }
    }
}

/// Handoff for Create Copy: Browse stashes the template, AddNoteView picks it up.
@MainActor
final class BrowseCopyHandoff: ObservableObject {
    static let shared = BrowseCopyHandoff()
    @Published var template: NewNoteTemplate?
    private init() {}
}

// MARK: - Export selected notes

struct BrowseExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let noteIDs: [NoteID]
    let cardIDs: [CardID]
    var model: BrowseModel

    @Dependency(\.importExportService) private var importExport
    @State private var includeMedia = true
    @State private var includeScheduling = false
    @State private var includeDeckConfigs = true
    @State private var status: String?
    @State private var working = false
    @State private var shareURL: IdentifiableURL?
    @State private var resolvedNotes: [NoteID]?
    @State private var resolvedCards: [CardID] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(scopeLabel)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textSecondary)
                    Toggle("Include media", isOn: $includeMedia)
                    Toggle("Include scheduling", isOn: $includeScheduling)
                    Toggle("Include deck presets", isOn: $includeDeckConfigs)
                }
                if let status {
                    Section { Text(status).amgiFont(.caption) }
                }
                Section {
                    Button {
                        Task { await export() }
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(working || scopeEmpty)
                }
            }
            .navigationTitle("Export Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await resolve() }
            .sheet(item: $shareURL) { item in
                BrowseShareSheet(url: item.url)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var scopeEmpty: Bool {
        (resolvedNotes ?? noteIDs).isEmpty && resolvedCards.isEmpty && cardIDs.isEmpty
    }

    private var scopeLabel: String {
        if !cardIDs.isEmpty || !resolvedCards.isEmpty {
            let n = resolvedCards.isEmpty ? cardIDs.count : resolvedCards.count
            return "\(n) card\(n == 1 ? "" : "s") selected — exports their notes."
        }
        let n = (resolvedNotes ?? noteIDs).count
        return "\(n) note\(n == 1 ? "" : "s") selected."
    }

    /// Cards resolve to their notes (export is note-granular); notes pass
    /// through. Resolution happens up front so the label and the export agree.
    private func resolve() async {
        if !cardIDs.isEmpty {
            resolvedCards = cardIDs
            resolvedNotes = await model.noteIDsOfCards(cardIDs)
        } else {
            resolvedNotes = noteIDs
        }
    }

    private func export() async {
        working = true
        defer { working = false }
        let notes = resolvedNotes ?? noteIDs
        // Card-scoped selections export via the `card_ids` limit arm so the
        // exact cards (not all sibling cards) land in the package.
        let useCards = !resolvedCards.isEmpty
        guard !notes.isEmpty || useCards else {
            status = "Nothing to export."
            return
        }
        let fileName = "amgi-selection-\(Int(Date().timeIntervalSince1970)).apkg"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        // Copy out of @State before the off-main hop: the backend closure is
        // @Sendable and must not capture MainActor-isolated state.
        let cards = resolvedCards
        let media = includeMedia
        let scheduling = includeScheduling
        let configs = includeDeckConfigs
        let path = outURL.path
        do {
            let service = importExport
            let count: UInt32 = try await backendOffload {
                if useCards {
                    try service.exportCardsPackage(
                        cards, path, scheduling, configs, media, false
                    )
                } else {
                    try service.exportNotesPackage(
                        notes, path, scheduling, configs, media, false
                    )
                }
            }
            status = "Exported \(count) note\(count == 1 ? "" : "s") to \(fileName)."
            shareURL = IdentifiableURL(url: outURL)
        } catch {
            status = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if canImport(UIKit)
import UIKit
struct BrowseShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
import AppKit
/// macOS share sheet via the native sharing picker (parity with
/// `UIActivityViewController` on iOS): reveals the file in Finder as a
/// fallback so the export is never stranded.
struct BrowseShareSheet: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
        let button = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])
        let reveal = NSButton(title: "Reveal in Finder", target: context.coordinator, action: #selector(Coordinator.reveal(_:)))
        reveal.bezelStyle = .inline
        reveal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reveal)
        NSLayoutConstraint.activate([
            reveal.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reveal.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 4),
        ])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject {
        let url: URL
        init(url: URL) { self.url = url }

        @objc func share(_ sender: NSButton) {
            guard let window = sender.window else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            _ = window
        }

        @objc func reveal(_ sender: Any) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
#endif

// MARK: - Change Note Type

struct ChangeNotetypeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let noteIDs: [NoteID]
    let cardIDs: [CardID]
    var model: BrowseModel

    @Dependency(\.notetypesClient) private var notetypes
    @State private var targets: [NotetypeID: String] = [:]
    @State private var selectedTarget: NotetypeID?
    @State private var info: ChangeNotetypeInfo?
    @State private var fieldMap: [Int32] = []
    @State private var templateMap: [Int32] = []
    @State private var status: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Target note type") {
                    Picker("Note type", selection: $selectedTarget) {
                        Text("Choose…").tag(nil as NotetypeID?)
                        ForEach(targets.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { id in
                            Text(targets[id] ?? "#\(id.rawValue)").tag(id as NotetypeID?)
                        }
                    }
                }
                if let info {
                    Section("Field mapping") {
                        ForEach(Array(info.oldFieldNames.enumerated()), id: \.offset) { idx, name in
                            Picker(name, selection: fieldBinding(idx)) {
                                Text("None").tag(Int32(-1))
                                ForEach(Array(info.newFieldNames.enumerated()), id: \.offset) { nIdx, nName in
                                    Text(nName).tag(Int32(nIdx))
                                }
                            }
                        }
                    }
                    Section("Template mapping") {
                        ForEach(Array(info.oldTemplateNames.enumerated()), id: \.offset) { idx, name in
                            Picker(name, selection: templateBinding(idx)) {
                                Text("None").tag(Int32(-1))
                                ForEach(Array(info.newTemplateNames.enumerated()), id: \.offset) { nIdx, nName in
                                    Text(nName).tag(Int32(nIdx))
                                }
                            }
                        }
                    }
                }
                if let status {
                    Section { Text(status).amgiFont(.caption) }
                }
                Section {
                    Button("Convert") { Task { await convert() } }
                        .disabled(working || selectedTarget == nil || info == nil)
                }
            }
            .navigationTitle("Change Note Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
            .onChange(of: selectedTarget) { _, _ in Task { await loadInfo() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        if let all = try? await notetypes.listAll() {
            targets = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
        }
    }

    private func loadInfo() async {
        guard let target = selectedTarget else { info = nil; return }
        let notes = await model.resolveTargetNotes(cardIDs: cardIDs, noteIDs: noteIDs)
        guard let first = notes.first,
              let note = await fetchNote(first),
              note.mid != target
        else { info = nil; return }
        info = try? await notetypes.changeInfo(note.mid, target)
        if let info {
            fieldMap = info.oldFieldNames.indices.map { Int32($0 < info.newFieldNames.count ? $0 : -1) }
            templateMap = info.oldTemplateNames.indices.map { Int32($0 < info.newTemplateNames.count ? $0 : -1) }
        }
    }

    private func fetchNote(_ id: NoteID) async -> NoteRecord? {
        @Dependency(\.noteClient) var notes
        return (try? await notes.fetch(id)) ?? nil
    }

    private func fieldBinding(_ idx: Int) -> Binding<Int32> {
        Binding(
            get: { idx < fieldMap.count ? fieldMap[idx] : Int32(-1) },
            set: {
                while fieldMap.count <= idx { fieldMap.append(-1) }
                fieldMap[idx] = $0
            }
        )
    }

    private func templateBinding(_ idx: Int) -> Binding<Int32> {
        Binding(
            get: { idx < templateMap.count ? templateMap[idx] : Int32(-1) },
            set: {
                while templateMap.count <= idx { templateMap.append(-1) }
                templateMap[idx] = $0
            }
        )
    }

    private func convert() async {
        guard let target = selectedTarget, let info else { return }
        let notes = await model.resolveTargetNotes(cardIDs: cardIDs, noteIDs: noteIDs)
        guard let first = notes.first,
              let note = await fetchNote(first),
              note.mid != target
        else {
            status = "Pick a different target type."
            return
        }
        working = true
        defer { working = false }
        do {
            try await notetypes.change(
                notes, note.mid, target, fieldMap, templateMap,
                info.currentSchema, info.oldNotetypeName, false
            )
            await model.refreshAfterMutation()
            dismiss()
        } catch {
            status = "Couldn't convert: \(error.localizedDescription)"
        }
    }
}

// MARK: - Filtered deck from query

struct FilteredDeckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let query: String

    @Dependency(\.decksService) private var decks
    @State private var name = "Browse Results"
    @State private var limit = 100
    @State private var order: FilteredDeckOrder = .oldestReviewedFirst
    @State private var reschedule = true
    @State private var status: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Search")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                    Text(query.isEmpty ? "deck:*" : query)
                        .amgiFont(.body)
                        .textSelection(.enabled)
                }
                Section("Deck") {
                    TextField("Name", text: $name)
                    Stepper("Limit \(limit)", value: $limit, in: 1...9999)
                    Picker("Order", selection: $order) {
                        ForEach(FilteredDeckOrder.allCases, id: \.self) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    Toggle("Reschedule cards", isOn: $reschedule)
                }
                if let status {
                    Section { Text(status).amgiFont(.caption) }
                }
                Section {
                    Button("Create & Build Filtered Deck") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                } footer: {
                    Text("Search, limit, order, and rescheduling land atomically via AddOrUpdateFilteredDeck, then the deck rebuilds.")
                }
            }
            .navigationTitle("Filtered Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        working = true
        defer { working = false }
        let spec = FilteredDeckSpec(
            name: trimmed,
            search: query.isEmpty ? "deck:*" : query,
            limit: UInt32(max(1, limit)),
            order: order,
            reschedule: reschedule
        )
        let service = decks
        do {
            let created = try await backendOffload { try service.createFilteredDeck(spec) }
            let gathered = try await backendOffload { try service.rebuildFilteredDeck(created.id) }
            status = "Built “\(trimmed)” with \(gathered) card\(gathered == 1 ? "" : "s")."
            dismiss()
        } catch {
            status = "Couldn't create deck: \(error.localizedDescription)"
        }
    }
}

// MARK: - Browser columns

struct BrowserColumnsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    var model: BrowseModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Columns follow the engine catalog (`AllBrowserColumns`). The active set persists per mode and drives both the list metadata and sort options.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Section(model.mode == .notes ? "Notes columns" : "Cards columns") {
                    ForEach(model.browserColumns, id: \.key) { col in
                        HStack {
                            Text(model.mode == .notes ? col.notesLabel : col.cardsLabel)
                                .foregroundStyle(palette.textPrimary)
                            Spacer()
                            if activeKeys.contains(col.key) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(col.key) }
                    }
                }
            }
            .navigationTitle("Columns")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var activeKeys: [String] {
        model.mode == .notes ? model.viewPrefs.notesColumns : model.viewPrefs.cardsColumns
    }

    private func toggle(_ key: String) {
        var keys = activeKeys
        if keys.contains(key) {
            keys.removeAll { $0 == key }
        } else {
            keys.append(key)
        }
        Task { await model.setActiveColumns(keys) }
    }
}

// MARK: - Saved search management

struct SavedSearchManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    var model: BrowseModel

    @State private var renameFrom: String?
    @State private var renameTo = ""
    @State private var conflict: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.savedSearches.searches) { saved in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(saved.name).foregroundStyle(palette.textPrimary)
                                Text(saved.query)
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Update") {
                                model.updateSavedSearch(named: saved.name)
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("Rename") {
                                renameFrom = saved.name
                                renameTo = saved.name
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            model.deleteSavedSearch(named: model.savedSearches.searches[i].name)
                        }
                    }
                } footer: {
                    Text("Saving an existing name asks before overwriting. Rename rejects collisions.")
                }
                Section("Defaults") {
                    TextField("Default search (applies to empty Browse)", text: defaultBinding)
                    Button("Use current query as default") {
                        model.setDefaultSearch(model.buildQuery())
                    }
                }
            }
            .navigationTitle("Saved Searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename saved search", isPresented: Binding(
                get: { renameFrom != nil },
                set: { if !$0 { renameFrom = nil } }
            )) {
                TextField("Name", text: $renameTo)
                Button("Rename") {
                    if let from = renameFrom {
                        if !model.renameSavedSearch(from: from, to: renameTo) {
                            conflict = "That name is already taken."
                        }
                    }
                    renameFrom = nil
                }
                Button("Cancel", role: .cancel) { renameFrom = nil }
            }
            .alert("Couldn't save", isPresented: Binding(
                get: { conflict != nil },
                set: { if !$0 { conflict = nil } }
            )) {
                Button("OK", role: .cancel) { conflict = nil }
            } message: {
                Text(conflict ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var defaultBinding: Binding<String> {
        Binding(
            get: { model.defaultSearch },
            set: { model.setDefaultSearch($0) }
        )
    }
}
