import SwiftUI
import AmgiUI
import AmgiTheme
import AmgiAppShared
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import Observation

/// A real field manager for a notetype schema.
///
/// Anki's notetype update endpoint accepts a complete `Notetype`; there is no
/// separate field mutation API. The model therefore edits the fetched mirror
/// and commits one atomic update. Names are also rewritten in template
/// references when a field is renamed, while deletion remains conservative
/// (required/protected fields and the final field cannot be removed).
@Observable
@MainActor
final class NotetypeFieldManagerModel {
    var fieldNames: [String] = []
    var isLoading = true
    var isSaving = false
    var errorMessage: String?

    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypesClient
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    private var notetype = Notetype()
    private var originalNotetype: Notetype?

    var displayName: String = ""

    var canSave: Bool {
        guard !isLoading, !isSaving, !fieldNames.isEmpty else { return false }
        let names = fieldNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return names.allSatisfy { !$0.isEmpty }
            && Set(names).count == names.count
    }

    var hasUnsavedChanges: Bool {
        guard let originalNotetype else { return false }
        return originalNotetype != notetype
    }

    func load(notetypeID: NotetypeID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await notetypesClient.get(notetypeID)
            notetype = fetched
            fieldNames = fetched.fields.map(\.name)
            displayName = fetched.name
            normalizeFieldOrder()
            originalNotetype = notetype
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setFieldName(_ name: String, at index: Int) {
        guard fieldNames.indices.contains(index),
              notetype.fields.indices.contains(index) else { return }
        let oldName = notetype.fields[index].name
        fieldNames[index] = name
        notetype.fields[index].name = name
        guard oldName != name, !oldName.isEmpty else { return }
        for templateIndex in notetype.templates.indices {
            var template = notetype.templates[templateIndex]
            template.config.qFormat = replacingFieldName(
                oldName,
                with: name,
                in: template.config.qFormat
            )
            template.config.aFormat = replacingFieldName(
                oldName,
                with: name,
                in: template.config.aFormat
            )
            template.config.qFormatBrowser = replacingFieldName(
                oldName,
                with: name,
                in: template.config.qFormatBrowser
            )
            template.config.aFormatBrowser = replacingFieldName(
                oldName,
                with: name,
                in: template.config.aFormatBrowser
            )
            notetype.templates[templateIndex] = template
        }
    }

    func addField() {
        let name = nextFieldName()
        notetype.fields.append(Notetype.Field(ord: notetype.fields.count, name: name))
        fieldNames.append(name)
        normalizeFieldOrder()
    }

    func canDeleteField(at index: Int) -> Bool {
        guard notetype.fields.indices.contains(index), notetype.fields.count > 1 else {
            return false
        }
        return !notetype.fields[index].config.preventDeletion
    }

    func deleteField(at index: Int) {
        guard canDeleteField(at: index) else { return }
        let removedSortIndex = notetype.config.sortFieldIdx
        notetype.fields.remove(at: index)
        fieldNames.remove(at: index)
        if removedSortIndex == index {
            notetype.config.sortFieldIdx = min(index, max(0, notetype.fields.count - 1))
        } else if index < removedSortIndex {
            notetype.config.sortFieldIdx = max(0, removedSortIndex - 1)
        }
        normalizeFieldOrder()
    }

    func moveField(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first,
              notetype.fields.indices.contains(sourceIndex) else { return }
        var fields = notetype.fields
        let field = fields.remove(at: sourceIndex)
        let insertionIndex = min(max(0, destination), fields.count)
        fields.insert(field, at: insertionIndex)
        notetype.fields = fields
        fieldNames = fields.map(\.name)

        let oldSortIndex = notetype.config.sortFieldIdx
        if sourceIndex == oldSortIndex {
            notetype.config.sortFieldIdx = insertionIndex
        } else if sourceIndex < oldSortIndex, insertionIndex >= oldSortIndex {
            notetype.config.sortFieldIdx = max(0, oldSortIndex - 1)
        } else if sourceIndex > oldSortIndex, insertionIndex <= oldSortIndex {
            notetype.config.sortFieldIdx = min(fields.count - 1, oldSortIndex + 1)
        }
        normalizeFieldOrder()
    }

    func moveField(from sourceIndex: Int, direction: Int) {
        let destination = sourceIndex + direction
        guard notetype.fields.indices.contains(sourceIndex),
              destination >= 0,
              destination < notetype.fields.count else { return }
        moveField(from: IndexSet(integer: sourceIndex), to: destination)
    }

    @discardableResult
    func save(onSaved: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard canSave else {
            errorMessage = "Every field needs a unique, non-empty name."
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        for index in notetype.fields.indices {
            notetype.fields[index].name = fieldNames[index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        normalizeFieldOrder()

        do {
            try await notetypesClient.update(notetype)
            collectionStore.markLocalMutation()
            originalNotetype = notetype
            fieldNames = notetype.fields.map(\.name)
            if let onSaved {
                await onSaved()
            }
            return true
        } catch {
            errorMessage = "Could not save fields: \(error.localizedDescription)"
            return false
        }
    }

    private static let fieldReferenceRegex = try! NSRegularExpression(
        pattern: #"\{\{([^{}]+)\}\}"#
    )

    /// Replaces only the field component of a template reference, leaving
    /// filters such as `{{cloze:Front}}` and `{{text:Front}}` intact.
    private func replacingFieldName(
        _ oldName: String,
        with newName: String,
        in source: String
    ) -> String {
        guard !oldName.isEmpty, !newName.isEmpty else { return source }
        let fullRange = NSRange(source.startIndex..., in: source)
        let matches = Self.fieldReferenceRegex.matches(in: source, range: fullRange)
        var result = source
        for match in matches.reversed() {
            guard let contentRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let content = String(result[contentRange])
            var fieldContent = Substring(content)
            var prefix = ""
            if let first = fieldContent.first, ["#", "^", "/"].contains(first) {
                prefix = String(first)
                fieldContent = fieldContent.dropFirst()
            }
            let components = fieldContent.split(separator: ":", omittingEmptySubsequences: false)
            guard let fieldComponent = components.last,
                  fieldComponent == Substring(oldName) else { continue }
            var replacementComponents = components
            replacementComponents[replacementComponents.count - 1] = Substring(newName)
            let replacement = "{{" + prefix + replacementComponents.joined(separator: ":") + "}}"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private func nextFieldName() -> String {
        let existing = Set(fieldNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var index = notetype.fields.count + 1
        while existing.contains("field \(index)") {
            index += 1
        }
        return "Field \(index)"
    }

    private func normalizeFieldOrder() {
        for index in notetype.fields.indices {
            notetype.fields[index].ord = index
        }
        if !notetype.fields.isEmpty {
            notetype.config.sortFieldIdx = min(
                max(0, notetype.config.sortFieldIdx),
                notetype.fields.count - 1
            )
        } else {
            notetype.config.sortFieldIdx = 0
        }
    }
}

struct NotetypeFieldManagerView: View {
    let notetypeId: NotetypeID
    let preferredName: String
    var onSaved: (@Sendable () async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var model = NotetypeFieldManagerModel()
    @FocusState private var focusedField: Int?
    @State private var pendingDeleteIndex: Int?

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading fields…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage, model.fieldNames.isEmpty {
                ContentUnavailableView(
                    "Could not load fields",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                fieldList
            }
        }
        .background(palette.background)
        .navigationTitle(model.displayName.isEmpty ? preferredName : model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(model.hasUnsavedChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save") {
                        Task {
                            if await model.save(onSaved: onSaved) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                    .keyboardShortcut(.defaultAction)
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .accessibilityLabel("Reorder fields")
            }
            #endif
        }
        .task { await model.load(notetypeID: notetypeId) }
        .onKeyPress { press in
            if press.key == .escape {
                dismiss()
                return .handled
            }
            if press.key == .return, model.canSave {
                Task {
                    if await model.save(onSaved: onSaved) {
                        dismiss()
                    }
                }
                return .handled
            }
            return .ignored
        }
        .alert(
            "Field update failed",
            isPresented: Binding(
                get: { model.errorMessage != nil && !model.fieldNames.isEmpty },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
        .alert(
            "Delete field?",
            isPresented: Binding(
                get: { pendingDeleteIndex != nil },
                set: { if !$0 { pendingDeleteIndex = nil } }
            ),
            presenting: pendingDeleteIndex
        ) { index in
            Button("Delete", role: .destructive) {
                model.deleteField(at: index)
                if focusedField == index {
                    focusedField = nil
                }
                pendingDeleteIndex = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { index in
            Text("Remove \"\(model.fieldNames[index])\"? Anki will update existing notes, and templates that reference it must be updated before saving.")
        }
    }

    private var fieldList: some View {
        List {
            Section {
                ForEach(model.fieldNames.indices, id: \.self) { index in
                    fieldRow(index)
                }
                .onMove { source, destination in
                    model.moveField(from: source, to: destination)
                }

                Button {
                    model.addField()
                    focusedField = model.fieldNames.count - 1
                } label: {
                    Label("Add Field", systemImage: "plus.circle.fill")
                }
                .accessibilityHint("Adds a field to the end of the notetype")
            } header: {
                Text("Fields")
            } footer: {
                Text("Use the arrows or Edit on iPhone and iPad to reorder. Renaming a field updates its template references on save.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func fieldRow(_ index: Int) -> some View {
        HStack(spacing: AmgiSpacing.sm) {
            TextField(
                "Field name",
                text: Binding(
                    get: { model.fieldNames[index] },
                    set: { model.setFieldName($0, at: index) }
                )
            )
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($focusedField, equals: index)
            .onSubmit {
                focusedField = index + 1 < model.fieldNames.count ? index + 1 : nil
            }
            .accessibilityLabel("Field \(index + 1) name")

            HStack(spacing: 0) {
                Button {
                    model.moveField(from: index, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 32, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .accessibilityLabel("Move field \(index + 1) up")

                Button {
                    model.moveField(from: index, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 32, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(index == model.fieldNames.count - 1)
                .accessibilityLabel("Move field \(index + 1) down")
            }

            Button(role: .destructive) {
                pendingDeleteIndex = index
            } label: {
                Image(systemName: "trash")
                    .frame(width: 34, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canDeleteField(at: index))
            .accessibilityLabel("Delete field \(index + 1)")
            .accessibilityHint("Removes this field from the notetype")
        }
        .listRowBackground(palette.surfaceElevated)
    }
}

#if DEBUG
#Preview {
    let notetype = Notetype(
        id: NotetypeID(1),
        name: "Basic",
        fields: [
            Notetype.Field(ord: 0, name: "Front"),
            Notetype.Field(ord: 1, name: "Back"),
        ],
        templates: [
            Notetype.Template(
                ord: 0,
                name: "Card 1",
                config: .init(qFormat: "{{Front}}", aFormat: "{{FrontSide}}<hr id=answer>{{Back}}")
            ),
        ]
    )
    let _ = prepareDependencies {
        $0.notetypesClient.get = { _ in notetype }
        $0.notetypesClient.update = { _ in }
    }
    return NavigationStack {
        NotetypeFieldManagerView(notetypeId: NotetypeID(1), preferredName: "Basic")
    }
}
#endif
