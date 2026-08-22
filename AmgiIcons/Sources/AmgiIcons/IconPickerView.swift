import Foundation
public import SwiftUI
import PhosphorSwift

/// Grid-based Phosphor icon picker with semantic search.
///
/// Browse mode (empty query) shows a curated "Top picks" grid plus an
/// opt-in full-catalog grid — 1,512 icons is too many to land on. Typing
/// switches to ranked semantic results over the full set (debounced
/// 150 ms via cancellable `.task(id:)` so keystrokes don't re-embed).
///
/// The picker only mutates `selection`; the host decides persistence and
/// the manual-override semantics around it.
public struct IconPickerView: View {
    @Binding public var selection: String?
    /// Called after a user-driven pick (`nil` = reset to automatic).
    public var onCommit: ((String?) -> Void)?

    @State private var query = ""
    @State private var searchResults: [String] = []
    @State private var showFullCatalog = false
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    public init(
        selection: Binding<String?>,
        onCommit: ((String?) -> Void)? = nil
    ) {
        self._selection = selection
        self.onCommit = onCommit
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                    searchField
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        browseContent
                    } else {
                        resultGrid(searchResults)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
            #endif
            .navigationTitle("Deck Icon")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Automatic") {
                        selection = nil
                        onCommit?(nil)
                        dismiss()
                    }
                    .disabled(selection == nil)
                    .accessibilityHint("Follow the deck name automatically")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .presentationSizing(.fitted)
        #endif
        .task(id: query) {
            // Cancellable debounce: re-embedding per keystroke wastes work;
            // SwiftUI cancels this task whenever `query` changes again.
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                searchResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let q = trimmed
            searchResults = await IconSuggester.shared.search(q, topK: 60)
        }
    }

    // MARK: - Sections

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search icons", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 8)
    }

    @ViewBuilder
    private var browseContent: some View {
        Text("Top Picks")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        grid(Ph.deckTopPicks.map(\.amgiCaseName))

        if showFullCatalog {
            Text("All Icons")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            grid(Ph.allCases.map(\.amgiCaseName))
        } else {
            Button {
                showFullCatalog = true
            } label: {
                Label(
                    "Show all \(Ph.allCases.count) icons",
                    systemImage: "square.grid.2x2"
                )
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
    }

    private func resultGrid(_ names: [String]) -> some View {
        Group {
            if names.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                grid(names)
            }
        }
    }

    private func grid(_ names: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(names, id: \.self) { name in
                cell(for: name)
            }
        }
    }

    private func cell(for name: String) -> some View {
        let isSelected = selection == name
        return Button {
            selection = name
            onCommit?(name)
        } label: {
            VStack(spacing: 5) {
                iconImage(for: name)
                    .frame(width: 26, height: 26)
                Text(name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).trimmingCharacters(in: .whitespaces))
    }

    @ViewBuilder
    private func iconImage(for name: String) -> some View {
        if let icon = Ph.amgi(named: name) {
            icon.regular
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.square.dashed")
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Browse") {
    IconPickerView(selection: .constant(nil))
}

#Preview("Selected") {
    IconPickerView(selection: .constant("flask"))
}
#endif
