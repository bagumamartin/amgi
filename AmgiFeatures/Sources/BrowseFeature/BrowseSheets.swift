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
    /// Last browser input (desktop remembers it per browser).
    var initialExpression = "1"
    let onApply: (String) -> Void

    @State private var customDays = 3
    /// Free-form day/range input with optional `!` interval-reset suffix.
    @State private var freeform = ""
    @State private var resetInterval = false

    /// Single-day presets use exact offsets (desktop parity); ranges stay
    /// available through the free-form field below.
    private var presets: [(label: String, expression: String)] {
        [
            ("Today", "0"),
            ("Tomorrow", "1"),
            ("In 3 days", "3"),
            ("In 7 days", "7"),
            ("In 14 days", "14"),
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    ForEach(presets, id: \.label) { preset in
                        Button(preset.label) {
                            onApply(suffixed(preset.expression))
                            dismiss()
                        }
                    }
                }
                Section("Custom (days out)") {
                    Stepper(value: $customDays, in: 0...365) {
                        Text(customDays == 0 ? "Today" : "+\(customDays) day\(customDays == 1 ? "" : "s")")
                    }
                    Button("Set \(customDays == 0 ? "today" : "+\(customDays)")") {
                        onApply(suffixed("\(customDays)"))
                        dismiss()
                    }
                }
                Section("Free-form (day or range, e.g. 4 or 3-7)") {
                    TextField("e.g. 4, 3-7, 2026-09-20", text: $freeform)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Reset interval (! suffix)", isOn: $resetInterval)
                    Button("Apply") {
                        onApply(suffixed(freeform.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(freeform.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section {
                    Text("Applies to review cards; the engine rejects the rest with an explanatory error. Last input is remembered for next time.")
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
            .onAppear { freeform = initialExpression }
        }
        .presentationDetents([.medium, .large])
    }

    private func suffixed(_ expr: String) -> String {
        resetInterval ? expr + "!" : expr
    }
}

// MARK: - Reposition (new-card order)

struct RepositionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let onApply: (_ start: UInt32, _ step: UInt32, _ randomize: Bool, _ shift: Bool) -> Void

    @AppStorage("browse.reposition.start") private var start = 1
    @AppStorage("browse.reposition.step") private var step = 1
    @AppStorage("browse.reposition.randomize") private var randomize = false
    @AppStorage("browse.reposition.shift") private var shift = false
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    Stepper("Start at \(start)", value: $start, in: 0...99_999)
                    Stepper("Step \(step)", value: $step, in: 1...1000)
                }
                Section {
                    Toggle("Randomize order", isOn: $randomize)
                    Toggle("Shift existing positions", isOn: $shift)
                }
                if let resultMessage {
                    Section {
                        Text(resultMessage)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.positive)
                    }
                }
                Section {
                    Text("New cards queue from position 0; start/step clamp to the queue bounds. Options are remembered for next time.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .navigationTitle("Reposition New Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(UInt32(max(0, start)), UInt32(max(1, step)), randomize, shift)
                        resultMessage = "Repositioned."
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
    /// Total result count for the "all results" scope label.
    var resultCount = 0
    let onApply: (_ search: String, _ replacement: String, _ regex: Bool, _ matchCase: Bool, _ fieldName: String?, _ tagsTarget: Bool, _ selectedOnly: Bool) async -> Int

    @State private var searchText = ""
    @State private var replacement = ""
    @State private var isRegex = false
    @State private var matchCase = false
    @State private var selectedField: String?
    @State private var tagsTarget = false
    @State private var selectedOnly = true
    @State private var resultMessage: String?
    @AppStorage("browse.find.history") private var findHistoryRaw = ""
    @AppStorage("browse.replace.history") private var replaceHistoryRaw = ""

    private var findHistory: [String] {
        findHistoryRaw.split(separator: "\n").map(String.init)
    }
    private var replaceHistory: [String] {
        replaceHistoryRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scope") {
                    Toggle("Only selected (\(selectionCount))", isOn: $selectedOnly)
                        .disabled(selectionCount == 0)
                    Text(scopeDescription)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Section("Find") {
                    TextField("Search text", text: $searchText, axis: .vertical)
                    Toggle("Regular expression", isOn: $isRegex)
                    Toggle("Match case", isOn: $matchCase)
                    if !findHistory.isEmpty {
                        Menu("Recent searches") {
                            ForEach(findHistory.prefix(8), id: \.self) { h in
                                Button(h) { searchText = h }
                            }
                        }
                    }
                }
                Section("Replace with") {
                    TextField("Replacement", text: $replacement, axis: .vertical)
                    if !replaceHistory.isEmpty {
                        Menu("Recent replacements") {
                            ForEach(replaceHistory.prefix(8), id: \.self) { h in
                                Button(h) { replacement = h }
                            }
                        }
                    }
                }
                Section("Target") {
                    Picker("Target", selection: $tagsTarget) {
                        Text("Fields").tag(false)
                        Text("Tags").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if !tagsTarget, !fieldNames.isEmpty {
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
                    if tagsTarget {
                        Text("Replaces tag text across the scope (desktop Tags target).")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    } else if fieldNames.isEmpty {
                        Text("Field list loads from the current scope; all fields stay targeted until then.")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
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
                            recordHistories()
                            let count = await onApply(
                                searchText, replacement, isRegex, matchCase,
                                tagsTarget ? nil : selectedField, tagsTarget,
                                selectedOnly && selectionCount > 0
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

    private var scopeDescription: String {
        if selectedOnly, selectionCount > 0 {
            return "Scoped to \(selectionCount) selected."
        }
        if resultCount > 0 {
            return "Scope: all \(resultCount) results."
        }
        return "Scope: collection-wide (no selection, no results)."
    }

    private func recordHistories() {
        if !searchText.isEmpty {
            var h = findHistory
            h.removeAll { $0 == searchText }
            h.insert(searchText, at: 0)
            findHistoryRaw = Array(h.prefix(20)).joined(separator: "\n")
        }
        if !replacement.isEmpty {
            var h = replaceHistory
            h.removeAll { $0 == replacement }
            h.insert(replacement, at: 0)
            replaceHistoryRaw = Array(h.prefix(20)).joined(separator: "\n")
        }
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
    @State private var tagMessage: String?
    @AppStorage("browse.dupes.field") private var rememberedField = ""
    @AppStorage("browse.dupes.search") private var rememberedSearch = ""

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
                if !notetypeFields.isEmpty {
                    if !rememberedField.isEmpty,
                       let idx = notetypeFields.firstIndex(of: rememberedField) {
                        selectedFieldIndex = idx
                    } else {
                        selectedFieldIndex = 0
                    }
                }
                if searchText.isEmpty { searchText = rememberedSearch }
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
                TextField("Restrict to search (optional)", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task {
                        let field = selectedFieldIndex < notetypeFields.count
                            ? notetypeFields[selectedFieldIndex] : "Front"
                        rememberedField = field
                        rememberedSearch = searchText
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
                .disabled(notetypeFields.isEmpty)
            }
            if !exactGroups.isEmpty {
                Button {
                    Task {
                        let all = exactGroups.flatMap { $0.noteIds.map { NoteID($0) } }
                        await onTagDuplicates(all)
                    }
                } label: {
                    Label(
                        tagMessage ?? "Tag Duplicates",
                        systemImage: "tag"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.bar)
    }

    /// Injected by the caller (BrowseView) for the Tag Duplicates action.
    var onTagDuplicates: ([NoteID]) async -> Void = { _ in }

    private func idRanges(_ ids: [Int64]) -> String {
        guard let first = ids.first, let last = ids.last else { return "" }
        return first == last ? "#\(first)" : "#\(first)–#\(last)"
    }}
