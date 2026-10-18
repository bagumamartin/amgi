import AmgiAppCore
import AmgiTheme
import AmgiUI
import SwiftUI

/// "Add Context": what the screen offered, the whole collection, and every
/// deck, searchable. Rows toggle, so the same list removes what it added.
struct AssistantContextPicker: View {
    let engine: AssistantEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var decks: [AssistantContext] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !onScreen.isEmpty {
                    Section("On Screen") {
                        ForEach(onScreen) { row($0) }
                    }
                }
                if matches(AssistantContext.collection) {
                    Section("Focus On") {
                        row(.collection)
                    }
                }
                Section("Decks") {
                    if !loaded {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if filteredDecks.isEmpty {
                        Text(query.isEmpty ? "No decks yet" : "No matching decks")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textTertiary)
                    }
                    ForEach(filteredDecks) { row($0) }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .searchable(text: $query, prompt: Text("Search decks"))
            .navigationTitle("Add Context")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                decks = await engine.decksForPicker()
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    /// The launch contexts, plus any chip the engine resolved from them, so
    /// a removed chapter or passage can come back.
    private var onScreen: [AssistantContext] {
        engine.launchContexts.filter { $0.type != .collection && $0.type != .deck && matches($0) }
    }

    private var filteredDecks: [AssistantContext] { decks.filter(matches) }

    private func matches(_ context: AssistantContext) -> Bool {
        query.isEmpty || context.title.localizedCaseInsensitiveContains(query) || context.subtitle.localizedCaseInsensitiveContains(query)
    }

    private func row(_ context: AssistantContext) -> some View {
        let attached = engine.isAttached(context)
        return Button {
            if attached {
                engine.remove(context)
            } else {
                Task { await engine.add(context) }
            }
        } label: {
            HStack(spacing: AmgiSpacing.md) {
                Image(systemName: context.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 30, height: 30)
                    .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.title)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(context.caption)
                        .amgiFont(.micro)
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: attached ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(attached ? palette.accent : palette.separator)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(attached ? .isSelected : [])
    }
}
