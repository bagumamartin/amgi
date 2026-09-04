// AmgiApp/Sources/Browse/BrowseListColumn.swift
import SwiftUI
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies
import AmgiTheme

/// Middle column: the notes/cards list plus its own header bar.
///
/// Mode and sort live in the header rather than the window toolbar. As
/// `.principal` toolbar items they rendered above whichever column SwiftUI
/// felt like, and the mode picker was duplicated inside the sort menu.
///
/// Selection is platform-shaped: macOS uses a multi-select `List(selection:)`
/// (⌘-click / ⇧-click, like Mail and desktop Anki), while iOS uses
/// single-selection to drive the collapsed split view's push, with long-press
/// entering the explicit batch-select mode.
struct BrowseListColumn: View {
    @Environment(\.palette) private var palette
    @Bindable var model: BrowseModel
    @Binding var selectionState: BrowseSelectionState
    let onSwipeDelete: (NoteRecord) -> Void
    /// Compact NavigationStack only: after focusing a row, push the detail
    /// route. Nil on the split-view path, where `List(selection:)` already
    /// drives the inspector column.
    var onOpenDetail: (() -> Void)? = nil

    #if os(macOS)
    @State private var multiSelection: Set<Int64> = []
    #else
    @State private var rowSelection: Int64?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statefulContent
        }
        .background(palette.background)
        #if os(macOS)
        .onChange(of: multiSelection) { _, new in applySelection(new) }
        .onChange(of: model.mode) { _, _ in multiSelection = [] }
        #else
        .onChange(of: rowSelection) { _, new in
            guard let new else { return }
            Task {
                await focusRow(new)
                onOpenDetail?()
            }
        }
        .onChange(of: model.mode) { _, _ in rowSelection = nil }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $model.mode) {
                ForEach(BrowseModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Show notes or cards")

            Spacer(minLength: 8)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(countLabel)
                    .amgiFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }

            Menu {
                Picker("Sort by", selection: $model.sortOrder) {
                    ForEach(BrowseModel.SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
            .help("Sort")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var countLabel: String {
        let count = model.ids.count
        let noun = model.mode == .notes ? "note" : "card"
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: - Selection

    /// macOS multi-select feeds the batch toolbar; a lone selection focuses
    /// the detail column instead. Keeping the inspector pinned to the last
    /// single selection avoids it flickering through a ⇧-click range.
    #if os(macOS)
    private func applySelection(_ ids: Set<Int64>) {
        // A single click is a peek, not a batch scope: publishing it would
        // silently narrow Find & Replace (which falls back to "all loaded
        // results" when nothing is selected) to that one note.
        selectionState.selectedNoteIDs = ids.count > 1 ? noteIDs(for: ids) : []
        if ids.count == 1, let only = ids.first {
            Task { await focusRow(only) }
        }
    }
    #endif

    private func noteIDs(for ids: Set<Int64>) -> Set<NoteID> {
        switch model.mode {
        case .notes:
            return Set(ids.map { NoteID($0) })
        case .cards:
            // Only hydrated rows can resolve a note; every visible row is.
            return Set(ids.compactMap { model.card(at: $0)?.nid })
        }
    }

    private func focusRow(_ idRaw: Int64) async {
        switch model.mode {
        case .notes: await model.focus(noteID: idRaw)
        case .cards: await model.focus(cardID: idRaw)
        }
    }

    /// iOS-only: the hand-rolled checkmark list. macOS never enters it —
    /// ⌘-click on the native list is the desktop idiom.
    private var showsCheckmarks: Bool {
        #if os(macOS)
        false
        #else
        selectionState.isSelectMode
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var statefulContent: some View {
        if model.ids.isEmpty && !model.isLoading {
            emptyState
        } else {
            itemList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            ContentUnavailableView(
                "No \(model.mode.title)",
                systemImage: "tray",
                description: Text("This selection has no \(model.mode.title.lowercased()) yet.")
            )
        } else if model.mode == .notes && model.searchTextIsPlainFreeText && canOfferSemanticFallback {
            ContentUnavailableView {
                Label("No direct matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing in your collection matches the grammar query.")
            } actions: {
                Button("Search meaning of “\(query)”") {
                    Task { await model.runSemanticFallback() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    @ViewBuilder
    private var itemList: some View {
        #if os(macOS)
        List(selection: $multiSelection) { listRows }
        #else
        if showsCheckmarks {
            List { listRows }
        } else {
            List(selection: $rowSelection) { listRows }
        }
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        if let notice = model.semanticNotice {
            Section {
                semanticNoticeRow(notice)
            }
            .selectionDisabled()
        }

        ForEach(Array(model.ids.prefix(model.loadedCount).enumerated()),
                id: \.element) { index, idRaw in
            row(for: idRaw, index: index)
                .tag(idRaw)
        }

        if model.hasMorePages || model.isLoading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .selectionDisabled()
        }
    }

    private func semanticNoticeRow(_ notice: String) -> some View {
        HStack {
            Image(systemName: "sparkles").foregroundStyle(palette.accent)
            Text(notice).amgiFont(.caption)
            Spacer()
            Button {
                model.clearSemanticNotice()
                model.searchText = ""
                model.scheduleSearch(immediate: true)
            } label: {
                Image(systemName: "xmark")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var canOfferSemanticFallback: Bool {
        SemanticNoteIndex.shared.isReady || SemanticNoteIndex.shared.progressDescription != nil
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for idRaw: Int64, index: Int) -> some View {
        switch model.mode {
        case .notes:
            if let note = model.note(at: idRaw) {
                noteRow(note, index: index)
            } else {
                hydratingRow(index: index)
            }
        case .cards:
            CardRowView(card: model.card(at: idRaw))
                .onAppear { loadMore(index) }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: NoteRecord, index: Int) -> some View {
        if showsCheckmarks {
            HStack {
                Image(systemName: selectionState.contains(note.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        selectionState.contains(note.id) ? palette.accent : palette.textSecondary
                    )
                NoteRowView(note: note, notetypeName: model.notetypeNames[note.mid])
            }
            .contentShape(Rectangle())
            .onTapGesture { selectionState.toggle(note.id) }
            .onAppear { loadMore(index) }
        } else {
            HStack {
                NoteRowView(note: note, notetypeName: model.notetypeNames[note.mid])
                NoteContextMenuButton(noteId: note.id) {
                    Task { await model.performSearch() }
                }
            }
            .onAppear { loadMore(index) }
            #if os(iOS)
            .onLongPressGesture(minimumDuration: 0.5) {
                selectionState.enterSelectMode(preselect: note.id)
            }
            #endif
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    onSwipeDelete(note)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func hydratingRow(index: Int) -> some View {
        HStack(spacing: 12) {
            Circle().fill(palette.surfaceElevated).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Capsule()
                    .fill(palette.surfaceElevated)
                    .frame(width: 160, height: 12)
                Capsule()
                    .fill(palette.surfaceElevated.opacity(0.6))
                    .frame(width: 100, height: 10)
            }
        }
        .opacity(0.7)
        .onAppear { loadMore(index) }
    }

    /// Row onAppear hook: extend the visible window toward the user.
    private func loadMore(_ index: Int) {
        Task { await model.loadMoreIfNeeded(index: index) }
    }
}

// MARK: - NoteContextMenuButton

/// Resolves the first cardId for a note lazily on first appear, then shows CardContextMenu.
@MainActor
struct NoteContextMenuButton: View {
    let noteId: NoteID
    var onSuccess: (() -> Void)?

    @Dependency(\.cardClient) var cardClient
    @State private var firstCardId: CardID?

    var body: some View {
        Group {
            if let cardId = firstCardId {
                CardContextMenu(
                    cardId: cardId,
                    noteId: noteId,
                    onSuccess: onSuccess
                )
            } else {
                Image(systemName: "ellipsis.circle")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: noteId) {
            guard firstCardId == nil else { return }
            firstCardId = (try? await cardClient.fetchByNote(noteId))?.first?.id
        }
    }
}

// MARK: - Rows

/// Notes-mode row: title + subtitle + trailing marked star.
struct NoteRowView: View {
    @Environment(\.palette) private var palette
    let note: NoteRecord
    let notetypeName: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(strippedTitle)
                    .amgiFont(.body)
                    .lineLimit(1)
                subtitleView
            }
            Spacer(minLength: 8)
            if hasMarkedTag {
                Image(systemName: "star.fill")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.customStudyBadge)
            }
        }
        .padding(.vertical, 2)
    }

    private var strippedTitle: String {
        note.sfld.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var subtitleView: some View {
        let parts = [notetypeName].compactMap { $0?.isEmpty == false ? $0 : nil } +
            note.tags.split(separator: " ").filter { $0 != "marked" }.map(String.init)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var hasMarkedTag: Bool {
        note.tags.split(separator: " ").contains { $0.caseInsensitiveCompare("marked") == .orderedSame }
    }
}

/// Cards-mode row: per-card granularity with scheduling info.
/// State dot colors bind to theme card-state slots (decisions.md rule).
struct CardRowView: View {
    @Environment(\.palette) private var palette
    let card: CardRecord?

    var body: some View {
        HStack(spacing: 10) {
            if let card {
                stateDot(queue: card.queue, type: card.type)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: card))
                        .amgiFont(.body)
                        .lineLimit(1)
                    Text(subtitle(for: card))
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                duePill(queue: card.queue, type: card.type, due: card.due)
            } else {
                // Hydrating placeholder mirrors hydratingRow geometry.
                Circle().fill(palette.surfaceElevated).frame(width: 10, height: 10)
                Text("Loading…")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func title(for card: CardRecord) -> String {
        "Card #\(card.id.rawValue)"
    }

    private func subtitle(for card: CardRecord) -> String {
        let typeName: String = switch card.type {
        case 0: "New"
        case 1: "Learning"
        case 2: "Review"
        case 3: "Relearning"
        default: ""
        }
        let flags = ["No flag", "Red", "Orange", "Green", "Blue", "Pink", "Turquoise", "Purple"]
        let flagName = flags[Int(card.flags & 0b111)]
        return [typeName.isEmpty ? nil : typeName, "Ease \(card.factor / 10)%"].compactMap { $0 }.joined(separator: " · ") + (flagName == "No flag" ? "" : " · \(flagName)")
    }

    private func stateDot(queue: Int16, type: Int16) -> some View {
        Circle().fill(dotColor(queue: queue, type: type)).frame(width: 10, height: 10)
    }

    private func dotColor(queue: Int16, type: Int16) -> Color {
        if queue < -1 { return palette.warning }
        if queue == -1 { return palette.cardStateSuspended }
        switch type {
        case 0: return palette.cardStateNew
        case 1: return palette.cardStateLearning
        case 3: return palette.cardStateRelearn
        default: return palette.cardStateReview
        }
    }

    @ViewBuilder
    private func duePill(queue: Int16, type: Int16, due: Int32) -> some View {
        if let text = dueText(queue: queue, type: type, due: due) {
            Text(text)
                .amgiFont(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(dotColor(queue: queue, type: type).opacity(0.14))
                .foregroundStyle(dotColor(queue: queue, type: type))
                .clipShape(Capsule())
        }
    }

    private func dueText(queue: Int16, type: Int16, due: Int32) -> String? {
        switch type {
        case 0:
            return "pos \(due)"
        default:
            // Learning epochs vs review days differ; coarse labels only —
            // exact formatting arrives with engine rows (P2d follow-up).
            return queue < 0 ? nil : (due > 86_400 ? "+\(due / 86_400)d" : "today")
        }
    }
}
