import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

/// Highlights, bookmarks, and full-book search for one book.
///
/// Reads the same `ReaderAnnotationModel` the reader drives, so a mark created
/// in the reader appears here without a second load path and a mark deleted
/// here disappears from the page on the next chapter paint.
struct ReaderAnnotationsSheet: View {
    let book: ReaderBook
    @Bindable var model: ReaderAnnotationModel
    /// Unfinished cards, frontmost first. They are listed here, beside the
    /// highlights, so a draft waiting for its answer is never only in a dock.
    var drafts: [ReaderCardDraft] = []
    let onJump: (ReaderAnnotation) -> Void
    var onResumeDraft: (ReaderCardDraft) -> Void = { _ in }
    var onDiscardDraft: (ReaderCardDraft) -> Void = { _ in }

    @State private var query = ""
    @State private var selection: KindSelection = .highlights

    enum KindSelection: String, CaseIterable, Identifiable {
        case highlights, bookmarks, drafts, search
        var id: String { rawValue }

        var title: String {
            switch self {
            case .highlights: "Highlights"
            case .bookmarks: "Bookmarks"
            case .drafts: "Drafts"
            case .search: "Search"
            }
        }
    }

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Kind", selection: $selection) {
                ForEach(KindSelection.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if selection == .search {
                searchField
            }

            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            if selection == .drafts {
                draftList
            } else {
                list
            }
        }
        .onAppear {
            // Opened from "N Unfinished Cards": land on them.
            if !drafts.isEmpty && model.highlights.isEmpty { selection = .drafts }
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .amgiScreenCanvas()
    }
}

private extension ReaderAnnotationsSheet {
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Annotations")
                    .amgiFont(.cardTitle)
                    .foregroundStyle(palette.textPrimary)
                Text(book.title)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Search highlights and notes", text: $query)
                .amgiFont(.body)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, _ in
                    // Clearing the field empties the list rather than dumping
                    // every annotation into it.
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.clearSearch()
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: AmgiRadius.small)
                .fill(palette.surfaceElevated)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    var list: some View {
        let rows = rowsForSelection
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { annotation in
                        row(annotation)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    var rowsForSelection: [ReaderAnnotation] {
        switch selection {
        case .highlights: model.highlights
        case .bookmarks: model.bookmarks
        case .search: model.searchHits.map(\.annotation)
        case .drafts: []
        }
    }

    @ViewBuilder
    var draftList: some View {
        if drafts.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(drafts) { draft in
                        draftRow(draft)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    func draftRow(_ draft: ReaderCardDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
                if let chapter = chapterTitle(chapterID: ReaderCardSession.sourceChapterID(of: draft)) {
                    Text(chapter)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(draft.createdAt, format: .dateTime.month(.abbreviated).day())
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }
            Text(draft.hasContent(.front) ? draft.front : "No front yet")
                .amgiFont(.body)
                .foregroundStyle(draft.hasContent(.front) ? palette.textPrimary : palette.textSecondary)
                .lineLimit(3)
            Text(draft.hasContent(.back) ? draft.back : "Waiting for an answer")
                .italic(!draft.hasContent(.back))
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(3)
            HStack(spacing: 14) {
                Button("Resume") { onResumeDraft(draft) }
                    .amgiFont(.captionBold)
                    .accessibilityLabel("Resume this card and go to where it started")
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    onDiscardDraft(draft)
                } label: {
                    Image(systemName: "trash").amgiFont(.caption)
                }
                .accessibilityLabel("Discard draft")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyTitle: String {
        switch selection {
        case .highlights: "No highlights"
        case .bookmarks: "No bookmarks"
        case .drafts: "No unfinished cards"
        case .search: query.isEmpty ? "Search" : "No matches"
        }
    }

    var emptyIcon: String {
        switch selection {
        case .highlights: "highlighter"
        case .bookmarks: "bookmark"
        case .drafts: "rectangle.stack"
        case .search: "magnifyingglass"
        }
    }

    var emptyMessage: String {
        switch selection {
        case .highlights:
            "Use the annotations menu in the reader to highlight the page you are on."
        case .bookmarks:
            "Bookmarks keep your place in a chapter you want to come back to."
        case .drafts:
            "Select text and choose Make Card. A card whose answer is further on waits here until you find it."
        case .search:
            query.isEmpty
                ? "Search across every highlight and note in this book."
                : "Nothing in this book matches “\(query)”."
        }
    }

    func row(_ annotation: ReaderAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: annotation.kind == .highlight ? "highlighter" : "bookmark")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
                if let chapter = chapterTitle(for: annotation) {
                    Text(chapter)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(annotation.createdAt, format: .dateTime.month(.abbreviated).day())
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }

            Text(annotation.excerpt)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(4)

            if let note = annotation.note, !note.isEmpty {
                Text(note)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(3)
            }

            HStack(spacing: 14) {
                Button("Go to") {
                    onJump(annotation)
                }
                .amgiFont(.captionBold)
                .accessibilityLabel("Go to the highlighted passage")

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    Task { await model.delete(annotation) }
                } label: {
                    Image(systemName: "trash")
                        .amgiFont(.caption)
                }
                .accessibilityLabel("Delete annotation")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    /// Chapter title from the anchor's chapter ID, when the book still has it.
    ///
    /// Nil after a re-import changes the book's identity — the annotation is
    /// still valid, it just cannot name where it is, so the row omits the
    /// chapter rather than showing a stale one.
    func chapterTitle(for annotation: ReaderAnnotation) -> String? {
        chapterTitle(chapterID: annotation.anchor.chapterID)
    }

    func chapterTitle(chapterID: Int64?) -> String? {
        guard let chapterID,
              let index = book.chapters.firstIndex(where: { $0.id == chapterID })
        else { return nil }
        return book.chapters[index].title
    }

    func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            model.clearSearch()
            return
        }
        Task { await model.search(trimmed, inBook: book.id) }
    }
}
