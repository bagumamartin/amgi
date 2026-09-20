// AmgiApp/Sources/Browse/BrowseFilterRailView.swift
import SwiftUI
import AmgiUI
import AnkiKit
import AmgiTheme

/// The seven-section filter rail (spec §5.5), presented as a sheet across
/// platforms for phase 3. Tap = replace query; row context menu offers
/// desktop's modifier semantics (AND / OR / Negate). Saved searches get
/// swipe-to-delete here until rename UI lands with engine-row columns.
struct BrowseFilterRailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @Bindable var model: BrowseModel
    let savedSearches: [SavedSearchStore.SavedSearch]
    let onDeleteSaved: (String) -> Void
    let onSaveCurrent: (String) -> Void

    @State private var newSavedName = ""
    @State private var showSaveField = false
    @State private var flagLabels = FlagLabelStore()
    @State private var renameFlag: UInt32?
    @State private var renameFlagTo = ""

    var body: some View {
        NavigationStack {
            List {
                if !savedSearches.isEmpty || canSaveCurrent {
                    savedSection
                }
                Section("Today") { nodeRows(BrowseFilterSections.today()) }
                Section("Card State") { stateRows }
                Section("Flags") { flagRows }
                Section("Decks") { nodeRows(BrowseFilterSections.decks(model.allDecks.map(\.name))) }
                Section("Note Types") { notetypeRows }
                Section("Tags") { nodeRows(BrowseFilterSections.tags(model.allTags)) }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var canSaveCurrent: Bool {
        !model.buildQuery().trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var savedSection: some View {
        Section {
            ForEach(savedSearches) { saved in
                row(title: saved.name, image: "heart", role: nil) {
                    model.searchText = saved.query
                    dismiss()
                } compositionMenu: { composition in
                    Task { await model.applyFilterNode(
                        FilterNode(title: saved.name, systemImage: "heart", fragment: saved.query, role: nil),
                        composition: composition
                    ) }
                    dismiss()
                }
            }
            .onDelete { offsets in
                for offset in offsets where offset < savedSearches.count {
                    onDeleteSaved(savedSearches[offset].name)
                }
            }
            if canSaveCurrent && !showSaveField {
                Button {
                    newSavedName = "Search \(savedSearches.count + 1)"
                    showSaveField = true
                } label: {
                    Label("Save current search…", systemImage: "plus.circle")
                }
            }
            if showSaveField {
                HStack {
                    TextField("Name", text: $newSavedName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        onSaveCurrent(newSavedName)
                        showSaveField = false
                    }
                    .disabled(newSavedName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Saved Searches")
        } footer: {
            Text("Synced to every device via your collection config.")
        }
    }

    @ViewBuilder
    private var stateRows: some View {
        ForEach(BrowseFilterSections.cardStates()) { node in
            nodeRow(node)
        }
    }

    @ViewBuilder
    private var notetypeRows: some View {
        ForEach(Array(model.notetypeNames.values).sorted(), id: \.self) { name in
            DisclosureGroup {
                let children = model.notetypeChildren[name]
                if let templates = children?.templates, !templates.isEmpty {
                    ForEach(Array(templates.enumerated()), id: \.offset) { idx, tmpl in
                        nodeRow(FilterNode(
                            title: tmpl,
                            systemImage: "application.braces",
                            fragment: "note:\"\(name)\" card:\(idx + 1)",
                            role: nil
                        ))
                    }
                }
                if let fields = children?.fields, !fields.isEmpty {
                    ForEach(fields, id: \.self) { field in
                        nodeRow(FilterNode(
                            title: field,
                            systemImage: "textbox",
                            fragment: "note:\"\(name)\" \"\(field):*\"",
                            role: nil
                        ))
                    }
                }
            } label: {
                nodeRow(FilterNode(
                    title: name, systemImage: "doc.text",
                    fragment: "note:\"\(name)\"", role: nil
                ))
            }
        }
    }

    @ViewBuilder
    private var flagRows: some View {
        ForEach(BrowseFilterSections.flags()) { node in
            HStack(spacing: 10) {
                flagGlyph(for: node)
                flagRowContent(node)
            }
        }
        .task { flagLabels.refresh() }
        .alert("Rename flag", isPresented: Binding(
            get: { renameFlag != nil },
            set: { if !$0 { renameFlag = nil } }
        )) {
            TextField("Label", text: $renameFlagTo)
            Button("Save") {
                if let flag = renameFlag { flagLabels.rename(flag: flag, to: renameFlagTo) }
                renameFlag = nil
            }
            Button("Reset", role: .destructive) {
                if let flag = renameFlag { flagLabels.reset(flag: flag) }
                renameFlag = nil
            }
            Button("Cancel", role: .cancel) { renameFlag = nil }
        }
    }

    private func flagRowContent(_ node: FilterNode) -> some View {
        let number: UInt32? = switch node.fragment {
        case "flag:0": nil
        case "flag:1": 1
        case "flag:2": 2
        case "flag:3": 3
        case "flag:4": 4
        case "flag:5": 5
        case "flag:6": 6
        case "flag:7": 7
        default: nil
        }
        let title: String = if node.fragment == "flag:0" {
            "No flag"
        } else if let number {
            flagLabels.label(for: number)
        } else {
            node.title
        }
        return HStack {
            Text(title)
                .foregroundStyle(palette.textPrimary)
            Spacer()
            if isActive(node) {
                Image(systemName: "checkmark")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.searchText = node.fragment
            dismiss()
        }
        .contextMenu {
            compositionButtons(node)
            if let number {
                Button {
                    renameFlag = number
                    renameFlagTo = flagLabels.label(for: number)
                } label: {
                    Label("Rename flag label…", systemImage: "pencil")
                }
            }
        }
    }

    private func nodeRows(_ nodes: [FilterNode]) -> some View {
        ForEach(nodes) { nodeRow($0) }
    }

    /// Flag colors reuse the selection-bar hues (Anki's seven brand flags).
    /// Fragments are canonical numeric `flag:0…7` (parser rejects names).
    @ViewBuilder
    private func flagGlyph(for node: FilterNode) -> some View {
        let color: Color = {
            if case .flag(let value) = node.role, let color = BrowseFlagSwatch.color(for: value) {
                return color
            }
            return palette.textTertiary
        }()
        Image(systemName: node.systemImage)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func nodeRow(_ node: FilterNode) -> some View {
        HStack(spacing: 10) {
            if let role = node.role {
                switch role {
                case .state(let stateColor):
                    Image(systemName: node.systemImage)
                        .foregroundStyle(stateColorValue(stateColor))
                case .flag:
                    EmptyView() // handled by flagRows
                }
            } else {
                Image(systemName: node.systemImage)
                    .foregroundStyle(palette.textSecondary)
            }
            railRowContent(node)
        }
    }

    private func railRowContent(_ node: FilterNode) -> some View {
        HStack {
            Text(node.title)
                .foregroundStyle(palette.textPrimary)
            Spacer()
            if isActive(node) {
                Image(systemName: "checkmark")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.searchText = node.fragment
            dismiss()
        }
        .contextMenu {
            compositionButtons(node)
        }
    }

    private func compositionButtons(_ node: FilterNode) -> some View {
        Group {
            Button {
                apply(node, .andWithExisting)
            } label: { Label("AND with current search", systemImage: "plus.forwardslash.minus") }
            Button {
                apply(node, .orWithExisting)
            } label: { Label("OR with current search", systemImage: "arrow.triangle.branch") }
            Button {
                Task {
                    await model.replaceNodeOfSameType(with: node.fragment)
                }
                dismiss()
            } label: { Label("Replace same-type filters", systemImage: "arrow.triangle.2.circlepath") }
            Button(role: .destructive) {
                apply(node, .negateAndAdd)
            } label: { Label("Exclude from current search", systemImage: "minus.circle") }
        }
    }

    private func apply(_ node: FilterNode, _ composition: BrowseModel.RailComposition) {
        Task {
            await model.applyFilterNode(node, composition: composition)
        }
        dismiss()
    }

    private func row(title: String, image: String, role: FilterNode.Role?,
                     action: @escaping () -> Void,
                     compositionMenu: @escaping (BrowseModel.RailComposition) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: image).foregroundStyle(palette.accent)
            Text(title).foregroundStyle(palette.textPrimary)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .contextMenu {
            Button { compositionMenu(.andWithExisting) } label: {
                Label("AND with current search", systemImage: "plus.forwardslash.minus")
            }
            Button { compositionMenu(.orWithExisting) } label: {
                Label("OR with current search", systemImage: "arrow.triangle.branch")
            }
        }
    }

    private func isActive(_ node: FilterNode) -> Bool {
        model.searchText.contains(node.fragment)
    }

    private func stateColorValue(_ color: BrowseModelStateColor) -> Color {
        switch color {
        case .newState: palette.cardStateNew
        case .learning: palette.cardStateLearning
        case .review: palette.cardStateReview
        case .suspended: palette.cardStateSuspended
        case .buried: palette.warning
        }
    }
}
