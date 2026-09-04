// AmgiApp/Sources/Browse/BrowseFilterRailView.swift
import SwiftUI
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
                Section("Note Types") { nodeRows(BrowseFilterSections.notetypes(Array(model.notetypeNames.values).sorted())) }
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
    private var flagRows: some View {
        ForEach(BrowseFilterSections.flags()) { node in
            HStack(spacing: 10) {
                flagGlyph(for: node)
                railRowContent(node)
            }
        }
    }

    private func nodeRows(_ nodes: [FilterNode]) -> some View {
        ForEach(nodes) { nodeRow($0) }
    }

    /// Flag colors reuse the selection-bar hues (Anki's seven brand flags).
    @ViewBuilder
    private func flagGlyph(for node: FilterNode) -> some View {
        let color: Color = switch node.fragment {
        case "-flag:any": palette.textTertiary
        case "flag:red": Color(hexFlag: 0xFF3B30)
        case "flag:orange": Color(hexFlag: 0xFF9500)
        case "flag:green": Color(hexFlag: 0x34C759)
        case "flag:blue": Color(hexFlag: 0x007AFF)
        case "flag:pink": Color(hexFlag: 0xFF2D55)
        case "flag:turquoise": Color(hexFlag: 0x32ADE6)
        case "flag:purple": Color(hexFlag: 0xAF52DE)
        default: palette.accent
        }
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

extension Color {
    init(hexFlag hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
