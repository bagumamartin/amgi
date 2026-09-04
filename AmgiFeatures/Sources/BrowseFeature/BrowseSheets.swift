// AmgiApp/Sources/Browse/BrowseSheets.swift
import SwiftUI
import AmgiUI
import AnkiKit
import AnkiClients
import AmgiTheme

// Sheets for Browse selection ops & power tools (spec §5.7, §5.9). All are
// pure presentation: they receive resolved state from the caller and push
// mutations through `BrowseModel`.

// MARK: - Change deck

struct ChangeDeckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let decks: [DeckInfo]
    let onMove: (DeckID) -> Void

    @State private var searchText = ""

    private var filtered: [DeckInfo] {
        searchText.isEmpty ? decks : decks.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { deck in
                Button {
                    onMove(deck.id)
                    dismiss()
                } label: {
                    Text(deck.name)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .searchable(text: $searchText, prompt: "Filter decks")
            .navigationTitle("Move to Deck")
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

// MARK: - Set due date

struct SetDueDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let onApply: (String) -> Void

    @State private var customDays = 3

    /// Interval expressions the engine parses for review cards.
    private var presets: [(label: String, expression: String)] {
        [
            ("Today", "0"),
            ("Tomorrow", "1"),
            ("In 3 days", "3-4"),
            ("In 7 days", "7-8"),
            ("In 2 weeks", "14-15"),
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    ForEach(presets, id: \.label) { preset in
                        Button(preset.label) {
                            onApply(preset.expression)
                            dismiss()
                        }
                    }
                }
                Section("Custom (days out)") {
                    Stepper(value: $customDays, in: 1...365) {
                        Text("+\(customDays) day\(customDays == 1 ? "" : "s")")
                    }
                    Button("Set +\(customDays)") {
                        onApply("\(customDays)-\(customDays + 1)")
                        dismiss()
                    }
                }
                Section {
                    Text("Applies to review cards; the engine rejects the rest with an explanatory error.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .navigationTitle("Set Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Reposition (new-card order)

struct RepositionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onApply: (_ start: UInt32, _ step: UInt32, _ randomize: Bool, _ shift: Bool) -> Void

    @State private var start = 1
    @State private var step = 1
    @State private var randomize = false
    @State private var shift = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    Stepper("Start at \(start)", value: $start, in: 1...99_999)
                    Stepper("Step \(step)", value: $step, in: 1...1000)
                }
                Section {
                    Toggle("Randomize order", isOn: $randomize)
                    Toggle("Shift existing positions", isOn: $shift)
                }
            }
            .navigationTitle("Reposition New Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(UInt32(start), UInt32(step), randomize, shift)
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

// MARK: - Find & replace (spec §5.7)

struct FindReplaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let fieldNames: [String]
    let selectionCount: Int
    let onApply: (_ search: String, _ replacement: String, _ regex: Bool, _ matchCase: Bool, _ fieldName: String?) async -> Int

    @State private var searchText = ""
    @State private var replacement = ""
    @State private var isRegex = false
    @State private var matchCase = false
    @State private var selectedField: String?
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if selectionCount > 0 {
                    Section {
                        Text("Scoped to \(selectionCount) selected note\(selectionCount == 1 ? "" : "s").")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                } else {
                    Section {
                        Text("Scope: current results.")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                Section("Find") {
                    TextField("Search text", text: $searchText, axis: .vertical)
                    Toggle("Regular expression", isOn: $isRegex)
                    Toggle("Match case", isOn: $matchCase)
                }
                Section("Replace with") {
                    TextField("Replacement", text: $replacement, axis: .vertical)
                }
                if !fieldNames.isEmpty {
                    Section("Field limit (optional)") {
                        Picker("Field", selection: Binding(
                            get: { selectedField ?? "" },
                            set: { selectedField = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("All fields").tag("")
                            ForEach(fieldNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                }
                if let resultMessage {
                    Section {
                        Text(resultMessage)
                            .foregroundStyle(palette.positive)
                    }
                }
            }
            .navigationTitle("Find & Replace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            let count = await onApply(
                                searchText, replacement, isRegex, matchCase, selectedField
                            )
                            resultMessage = count > 0
                                ? "Updated \(count) note\(count == 1 ? "" : "s")."
                                : "No changes."
                        }
                    }
                    .disabled(searchText.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Find duplicates (spec §5.9 — exact aux RPC + cosine clusters)

struct FindDuplicatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let notetypeFields: [String]

    /// Exact grouping via the rslib aux service.
    let runExactScan: (_ fieldName: String, _ searchText: String) async -> FindDuplicatesResult?
    /// Fuzzy groups computed from the embedding corpus.
    let runNearScan: () -> [[Int64]]
    /// Opens a nid:(…) search for a group.
    let openGroup: ([Int64]) -> Void

    @State private var searchText = ""
    @State private var selectedFieldIndex = 0
    @State private var exactGroups: [FindDuplicatesResult.Group] = []
    @State private var exactSummary: String?
    @State private var nearGroups: [[Int64]] = []

    var body: some View {
        NavigationStack {
            List {
                exactSection
                nearSection
            }
            .safeAreaInset(edge: .bottom) { scanControls }
            .navigationTitle("Find Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if !notetypeFields.isEmpty { selectedFieldIndex = 0 }
                nearGroups = runNearScan()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var exactSection: some View {
        Section {
            if exactGroups.isEmpty {
                Text(exactSummary ?? "Pick a field and search to group exact matches.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            } else {
                ForEach(Array(exactGroups.enumerated()), id: \.offset) { _, group in
                    Button {
                        openGroup(group.noteIds)
                    } label: {
                        HStack {
                            Text(group.value.isEmpty ? "(empty)" : group.value)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.noteIds.count)")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                            Image(systemName: "chevron.right")
                                .amgiFont(.micro)
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                }
            }
        } header: {
            Text("Exact")
        } footer: {
            if let summary = exactSummary { Text(summary) }
        }
    }

    private var nearSection: some View {
        Section("Semantic near-duplicates") {
            if nearGroups.isEmpty {
                Text("No fuzzy clusters above \(Int(SemanticNoteIndex.nearDupeThreshold * 100))% similarity yet — the index fills as you browse.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            } else {
                ForEach(Array(nearGroups.enumerated()), id: \.offset) { _, ids in
                    Button {
                        openGroup(ids)
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(palette.accent)
                            Text("\(ids.count) similar notes")
                            Spacer()
                            Text(idRanges(ids))
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var scanControls: some View {
        VStack(spacing: 10) {
            Picker("Field", selection: $selectedFieldIndex) {
                ForEach(Array(notetypeFields.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                TextField("Field contains…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task {
                        let field = selectedFieldIndex < notetypeFields.count
                            ? notetypeFields[selectedFieldIndex] : "Front"
                        let result = await runExactScan(field, searchText)
                        exactGroups = result?.groups ?? []
                        exactSummary = result.map {
                            "\($0.groups.count) group\($0.groups.count == 1 ? "" : "s") across \($0.notesScanned) notes scanned"
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchText.isEmpty || notetypeFields.isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func idRanges(_ ids: [Int64]) -> String {
        guard let first = ids.first, let last = ids.last else { return "" }
        return first == last ? "#\(first)" : "#\(first)–#\(last)"
    }}
