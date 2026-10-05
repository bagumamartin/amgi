import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

/// Apple Books-style unified Table of Contents, Bookmarks, and Notes sheet.
///
/// Serves both EPUB and PDF readers:
/// - **Contents**: Displays chapter list (EPUB) or outline tree (PDF), with active section highlighted.
/// - **Bookmarks**: Saved bookmarks with timestamps and page labels, swipe-to-delete.
/// - **Notes & Highlights**: Color-coded highlights and flashcard notes.
struct ReaderContentsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case contents = "Contents"
        case bookmarks = "Bookmarks"
        case notes = "Notes"

        var id: String { rawValue }
    }

    struct OutlineItem: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let pageIndex: Int
        let pageLabel: String?
        let depth: Int
        let isCurrent: Bool

        init(
            id: String,
            title: String,
            pageIndex: Int,
            pageLabel: String? = nil,
            depth: Int = 0,
            isCurrent: Bool = false
        ) {
            self.id = id
            self.title = title
            self.pageIndex = pageIndex
            self.pageLabel = pageLabel
            self.depth = depth
            self.isCurrent = isCurrent
        }
    }

    struct BookmarkItem: Identifiable, Equatable, Sendable {
        let id: String
        let pageIndex: Int
        let pageLabel: String
        let title: String
        let subtitle: String?
        let date: Date

        init(
            id: String,
            pageIndex: Int,
            pageLabel: String,
            title: String,
            subtitle: String? = nil,
            date: Date = Date()
        ) {
            self.id = id
            self.pageIndex = pageIndex
            self.pageLabel = pageLabel
            self.title = title
            self.subtitle = subtitle
            self.date = date
        }
    }

    struct NoteItem: Identifiable, Equatable, Sendable {
        let id: String
        let pageIndex: Int
        let pageLabel: String
        let quote: String
        let note: String?
        let colorHex: String?

        init(
            id: String,
            pageIndex: Int,
            pageLabel: String,
            quote: String,
            note: String? = nil,
            colorHex: String? = nil
        ) {
            self.id = id
            self.pageIndex = pageIndex
            self.pageLabel = pageLabel
            self.quote = quote
            self.note = note
            self.colorHex = colorHex
        }
    }

    let bookTitle: String
    let contentsTabTitle: String
    let notesTabTitle: String
    let headerSubtitle: String?
    let onHeaderSubtitleTap: (() -> Void)?
    let doneUsesCheckmark: Bool
    let outlineItems: [OutlineItem]
    let bookmarks: [BookmarkItem]
    let notes: [NoteItem]
    let onSelectOutline: (OutlineItem) -> Void
    let onSelectBookmark: (BookmarkItem) -> Void
    let onDeleteBookmark: ((BookmarkItem) -> Void)?
    let onSelectNote: (NoteItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var selectedTab: Tab = .contents

    init(
        bookTitle: String,
        outlineItems: [OutlineItem],
        bookmarks: [BookmarkItem] = [],
        notes: [NoteItem] = [],
        initialTab: Tab = .contents,
        contentsTabTitle: String = Tab.contents.rawValue,
        notesTabTitle: String = Tab.notes.rawValue,
        headerSubtitle: String? = nil,
        onHeaderSubtitleTap: (() -> Void)? = nil,
        doneUsesCheckmark: Bool = false,
        onSelectOutline: @escaping (OutlineItem) -> Void,
        onSelectBookmark: @escaping (BookmarkItem) -> Void,
        onDeleteBookmark: ((BookmarkItem) -> Void)? = nil,
        onSelectNote: @escaping (NoteItem) -> Void
    ) {
        self.bookTitle = bookTitle
        self.contentsTabTitle = contentsTabTitle
        self.notesTabTitle = notesTabTitle
        self.headerSubtitle = headerSubtitle
        self.onHeaderSubtitleTap = onHeaderSubtitleTap
        self.doneUsesCheckmark = doneUsesCheckmark
        self.outlineItems = outlineItems
        self.bookmarks = bookmarks
        self.notes = notes
        _selectedTab = State(initialValue: initialTab)
        self.onSelectOutline = onSelectOutline
        self.onSelectBookmark = onSelectBookmark
        self.onDeleteBookmark = onDeleteBookmark
        self.onSelectNote = onSelectNote
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let headerSubtitle {
                    Group {
                        if let onHeaderSubtitleTap {
                            Button(action: onHeaderSubtitleTap) {
                                HStack(spacing: 6) {
                                    Text(headerSubtitle)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(headerSubtitle)
                        }
                    }
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                    .padding(.top, 10)
                    .padding(.bottom, 5)
                }

                // Segmented picker
                Picker("Section", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tabTitle(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Content list
                Group {
                    switch selectedTab {
                    case .contents:
                        contentsList
                    case .bookmarks:
                        bookmarksList
                    case .notes:
                        notesList
                    }
                }
            }
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if doneUsesCheckmark {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.primary.opacity(0.84), in: Circle())
                        }
                        .accessibilityLabel("Done")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private func tabTitle(for tab: Tab) -> String {
        switch tab {
        case .contents: contentsTabTitle
        case .bookmarks: Tab.bookmarks.rawValue
        case .notes: notesTabTitle
        }
    }

    // MARK: - Subviews

    private var contentsList: some View {
        List {
            if outlineItems.isEmpty {
                ContentUnavailableView(
                    "No Outline Available",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This document does not define a table of contents.")
                )
            } else {
                ForEach(outlineItems) { item in
                    Button {
                        onSelectOutline(item)
                        dismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title)
                                .amgiFont(item.isCurrent ? .bodyEmphasis : .body)
                                .foregroundStyle(item.isCurrent ? palette.accent : palette.textPrimary)
                                .padding(.leading, CGFloat(item.depth * 14))

                            Spacer(minLength: 8)

                            if let label = item.pageLabel {
                                Text(label)
                                    .amgiFont(.caption, .monospacedDigits)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }

    private var bookmarksList: some View {
        List {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text("Tap the bookmark icon in the top toolbar to save your place.")
                )
            } else {
                ForEach(bookmarks) { item in
                    Button {
                        onSelectBookmark(item)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Page \(item.pageLabel)")
                                    .amgiFont(.bodyEmphasis)
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Text(item.date, style: .date)
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                            }
                            if !item.title.isEmpty {
                                Text(item.title)
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    guard let onDeleteBookmark else { return }
                    for index in indexSet {
                        onDeleteBookmark(bookmarks[index])
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var notesList: some View {
        List {
            if notes.isEmpty {
                ContentUnavailableView(
                    "No Notes or Highlights",
                    systemImage: "highlighter",
                    description: Text("Select text while reading to add highlights or make Anki cards.")
                )
            } else {
                ForEach(notes) { item in
                    Button {
                        onSelectNote(item)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(color(for: item.colorHex))
                                .frame(width: 10, height: 10)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.quote)
                                    .amgiFont(.body)
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(3)

                                if let note = item.note, !note.isEmpty {
                                    Text(note)
                                        .amgiFont(.captionBold)
                                        .foregroundStyle(palette.accent)
                                }

                                Text("Page \(item.pageLabel)")
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }

    private func color(for hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return palette.accent }
        return ReaderThemeColor.color(fromHex: hex, fallback: palette.accent)
    }
}
