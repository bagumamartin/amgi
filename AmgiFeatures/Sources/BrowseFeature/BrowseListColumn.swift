// AmgiApp/Sources/Browse/BrowseListColumn.swift
import SwiftUI
import AmgiAppShared
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
/// single-selection to drive the collapsed split view's push. Long-press
/// applies a per-row context menu (same as the source column). Batch select
/// is an explicit mode from the overflow Select item.
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
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.searchError {
                searchErrorBanner(error)
            }
            Divider()
            statefulContent
        }
        .amgiScreenCanvas()
        #if os(macOS)
        .onChange(of: multiSelection) { _, new in applySelection(new) }
        .onChange(of: model.mode) { _, _ in
            multiSelection = []
            model.persistViewPrefs()
        }
        .onChange(of: model.sortOrder) { _, _ in model.persistViewPrefs() }
        #else
        .onChange(of: model.mode) { _, _ in
            selectionState.exitSelectMode()
            model.persistViewPrefs()
        }
        .onChange(of: model.sortOrder) { _, _ in model.persistViewPrefs() }
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
                    .accessibilityLabel(selectionSummary)
            }

            Menu {
                Picker("Sort by", selection: $model.sortOrder) {
                    ForEach(BrowseModel.SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                Divider()
                Button {
                    model.toggleSortDirection()
                } label: {
                    Label(
                        model.effectiveSortReverse ? "Sort descending" : "Sort ascending",
                        systemImage: model.effectiveSortReverse ? "arrow.down" : "arrow.up"
                    )
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
            .help("Sort (column and direction persist per mode)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var countLabel: String {
        let count = model.ids.count
        let noun = model.mode == .notes ? "note" : "card"
        let base = "\(count) \(noun)\(count == 1 ? "" : "s")"
        if selectionState.isEmpty { return base }
        let sel = selectionState.count
        let selNoun = model.mode == .notes ? "note" : "card"
        return "\(base) · \(sel) selected \(selNoun)\(sel == 1 ? "" : "s")"
    }

    private var selectionSummary: String {
        let count = model.ids.count
        if selectionState.isEmpty { return "\(count) results" }
        return "\(count) results, \(selectionState.count) selected"
    }

    private func searchErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.warning)
            Text(error)
                .amgiFont(.caption)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.warning.opacity(0.12))
    }

    // MARK: - Selection

    /// macOS multi-select feeds the batch toolbar; a lone selection focuses
    /// the detail column instead. Keeping the inspector pinned to the last
    /// single selection avoids it flickering through a ⇧-click range.
    /// Cards mode publishes card IDs directly (upstream parity) so sibling
    /// cards are never pulled in; notes mode publishes note IDs.
    #if os(macOS)
    private func applySelection(_ ids: Set<Int64>) {
        // A single click is a peek, not a batch scope: publishing it would
        // silently narrow Find & Replace (which falls back to all results
        // when nothing is selected) to that one row.
        switch model.mode {
        case .notes:
            selectionState.selectedNoteIDs = ids.count > 1 ? Set(ids.map { NoteID($0) }) : []
            selectionState.selectedCardIDs = []
        case .cards:
            selectionState.selectedCardIDs = ids.count > 1 ? Set(ids.map { CardID($0) }) : Set(ids.map { CardID($0) })
            selectionState.selectedNoteIDs = []
            // Single-card peek must still arm card scope (sibling-card
            // toolbar hid before because it required >1 *note* id).
            if ids.count == 1, let only = ids.first {
                Task { await focusRow(only) }
                return
            }
        }
        if ids.count == 1, let only = ids.first {
            Task { await focusRow(only) }
        }
    }
    #endif

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
            .scrollContentBackground(.hidden)
        #else
        List { listRows }
            .scrollContentBackground(.hidden)
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
            cardRow(idRaw: idRaw, index: index)
        }
    }

    @ViewBuilder
    private func cardRow(idRaw: Int64, index: Int) -> some View {
        if showsCheckmarks, let card = model.card(at: idRaw) {
            HStack {
                Image(systemName: selectionState.contains(card: card.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        selectionState.contains(card: card.id) ? palette.accent : palette.textSecondary
                    )
                CardRowView(card: card, dueText: model.dueLabel(for: card))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selectionState.toggle(card: card.id) }
            .onAppear { loadMore(index) }
        } else {
            let card = model.card(at: idRaw)
            BrowseActionRow(
                browseModel: model,
                cardId: card?.id ?? CardID(idRaw),
                noteId: card?.nid,
                showsOverflowButton: false,
                onActivate: {
                    #if os(iOS)
                    activateRow(idRaw)
                    #endif
                },
                onSuccess: {
                    Task { await model.performSearch() }
                }
            ) {
                CardRowView(
                    card: card,
                    dueText: card.flatMap { model.dueLabel(for: $0) },
                    noteTitle: card.flatMap { model.parentNoteTitle(for: $0) }
                )
            }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selectionState.toggle(note.id) }
            .onAppear { loadMore(index) }
        } else {
            BrowseActionRow(
                browseModel: model,
                noteId: note.id,
                showsOverflowButton: true,
                onActivate: {
                    #if os(iOS)
                    activateRow(note.id.rawValue)
                    #endif
                },
                onSuccess: {
                    Task { await model.performSearch() }
                }
            ) {
                NoteRowView(note: note, notetypeName: model.notetypeNames[note.mid])
            }
            .onAppear { loadMore(index) }
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

    #if os(iOS)
    private func activateRow(_ idRaw: Int64) {
        Task {
            await focusRow(idRaw)
            onOpenDetail?()
        }
    }
    #endif
}

// MARK: - Row actions (ellipsis + long-press)

/// Shared chrome for a browse row: optional trailing `…` menu, and a
/// long-press / right-click context menu with the same card actions. Resolves
/// a note's first card lazily so notes-mode rows can host card-scoped ops.
@MainActor
private struct BrowseActionRow<Content: View>: View {
    var browseModel: BrowseModel
    var cardId: CardID? = nil
    var noteId: NoteID? = nil
    var showsOverflowButton: Bool
    var onActivate: (() -> Void)? = nil
    var onSuccess: (() -> Void)? = nil
    @ViewBuilder var content: Content

    @State private var resolvedCardId: CardID?
    @State private var menuModel = CardContextMenuModel()
    @State private var confirmDeleteNote = false

    var body: some View {
        HStack {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                #if os(iOS)
                .onTapGesture { onActivate?() }
                #endif
                .contextMenu {
                    if let id = effectiveCardId {
                        actionMenu(cardId: id)
                    }
                }
            if showsOverflowButton {
                overflowButton
            }
        }
        .cardActionPresentations(
            model: menuModel,
            cardId: effectiveCardId,
            noteId: noteId,
            confirmDeleteNote: $confirmDeleteNote,
            onAction: { _ in onSuccess?() }
        )
        .task(id: taskIdentity) {
            if let cardId {
                resolvedCardId = cardId
            } else if let noteId {
                resolvedCardId = await browseModel.firstCardID(for: noteId)
            }
        }
    }

    @ViewBuilder
    private func actionMenu(cardId: CardID) -> some View {
        CardActionMenuSections(
            model: menuModel,
            cardId: cardId,
            noteId: noteId,
            confirmDeleteNote: $confirmDeleteNote,
            onAction: { _ in onSuccess?() }
        )
    }

    private var effectiveCardId: CardID? { resolvedCardId ?? cardId }

    private var taskIdentity: Int64 {
        cardId?.rawValue ?? noteId?.rawValue ?? 0
    }

    @ViewBuilder
    private var overflowButton: some View {
        if let id = effectiveCardId {
            Menu {
                actionMenu(cardId: id)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .amgiFont(.bodyEmphasis)
            }
            .accessibilityLabel("Card actions")
        } else {
            Image(systemName: "ellipsis.circle")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(.tertiary)
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
        browsePlainTextTitle(for: note, fallback: notetypeName)
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let subtitle = composeNoteSubtitle(notetypeName: notetypeName, tags: note.tags) {
            Text(subtitle)
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
/// Titles prefer recognizable content: the parent note's sort field when the
/// row's note is hydrated, else the template ordinal — never a bare id.
struct CardRowView: View {
    @Environment(\.palette) private var palette
    let card: CardRecord?
    /// Scheduler-aware due label from `BrowseModel.dueLabel(for:)`; nil hides the pill.
    var dueText: String? = nil
    /// Recognizable title source (parent note sort field, HTML-stripped).
    var noteTitle: String? = nil
    /// Engine-rendered row (question/answer cells + semantic color) when the
    /// active column set has been fetched; takes precedence for title.
    var engineRow: BrowserRowData? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let card {
                stateDot(queue: card.queue, type: card.type, flags: card.flags)
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
                flagPill(flags: card.flags)
                duePill(queue: card.queue, type: card.type)
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
        if let engineRow, let first = engineRow.cells.first, !first.text.isEmpty {
            return first.text
        }
        if let noteTitle, !noteTitle.isEmpty { return noteTitle }
        return "Card \(card.ord + 1)"
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
        var parts = [String]()
        if !typeName.isEmpty { parts.append(typeName) }
        parts.append("Card \(card.ord + 1)")
        if card.factor > 0 { parts.append("Ease \(card.factor / 10)%") }
        if flagName != "No flag" { parts.append(flagName) }
        return parts.joined(separator: " · ")
    }

    private func stateDot(queue: Int16, type: Int16, flags: Int32? = nil) -> some View {
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
    private func flagPill(flags: Int32) -> some View {
        let idx = Int(flags & 0b111)
        if idx != 0 {
            let color: Color = switch idx {
            case 1: Color(red: 1, green: 0.23, blue: 0.19)
            case 2: Color(red: 1, green: 0.58, blue: 0)
            case 3: Color(red: 0.2, green: 0.78, blue: 0.35)
            case 4: Color(red: 0, green: 0.48, blue: 1)
            case 5: Color(red: 1, green: 0.18, blue: 0.33)
            case 6: Color(red: 0.2, green: 0.68, blue: 0.9)
            default: Color(red: 0.69, green: 0.32, blue: 0.87)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func duePill(queue: Int16, type: Int16) -> some View {
        if let text = dueText {
            Text(text)
                .amgiFont(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(dotColor(queue: queue, type: type).opacity(0.14))
                .foregroundStyle(dotColor(queue: queue, type: type))
                .clipShape(Capsule())
        }
    }
}
