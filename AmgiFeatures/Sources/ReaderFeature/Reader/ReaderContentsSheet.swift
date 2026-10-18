import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
        /// A plain highlight, or a capture for a card — saved or still a
        /// draft — which the list shows with its passages and pictures.
        enum Kind: Sendable { case highlight, card, draft }

        let id: String
        let pageIndex: Int
        let pageLabel: String
        let quote: String
        let note: String?
        let colorHex: String?
        let kind: Kind
        /// A capture's other passage, usually its answer.
        let secondary: String?
        /// A capture's areas, as pictures.
        let images: [URL]

        init(
            id: String,
            pageIndex: Int,
            pageLabel: String,
            quote: String,
            note: String? = nil,
            colorHex: String? = nil,
            kind: Kind = .highlight,
            secondary: String? = nil,
            images: [URL] = []
        ) {
            self.id = id
            self.pageIndex = pageIndex
            self.pageLabel = pageLabel
            self.quote = quote
            self.note = note
            self.colorHex = colorHex
            self.kind = kind
            self.secondary = secondary
            self.images = images
        }
    }

    /// What can be done to a listed mark from the list itself. Each is
    /// optional: a reader that cannot recolour its highlights leaves that out.
    struct NoteActions {
        /// Open a card's note or a draft's card sheet.
        var edit: ((NoteItem) -> Void)?
        /// Set a highlight's note.
        var setNote: ((NoteItem, String) -> Void)?
        /// Delete a highlight, discard a draft, or take a card's highlights
        /// off the page (the card stays in the collection).
        var remove: ((NoteItem) -> Void)?
        /// Delete a card from the collection, with its highlights.
        var deleteCard: ((NoteItem) -> Void)?
        var recolour: ((NoteItem, PDFAnnotationColour) -> Void)?
        /// Whether a mark's colour can be changed here.
        var canRecolour: (NoteItem) -> Bool = { $0.kind != .highlight }
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
    let noteActions: NoteActions

    @Environment(\.dismiss) private var dismiss
    /// A card waiting on "Remove Highlight" or "Delete Card Too".
    @State private var pendingCardRemoval: NoteItem?
    /// A highlight whose note is being written.
    @State private var noteEditing: NoteItem?
    @State private var noteText = ""
    @Environment(\.palette) private var palette
    @State private var selectedTab: Tab = .contents
    /// Rows take taps only once the sheet has finished arriving. The touch
    /// that opened it could otherwise land on whatever row slid under the
    /// finger — a jump the reader never chose.
    @State private var rowsAcceptTaps = false

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
        onSelectNote: @escaping (NoteItem) -> Void,
        noteActions: NoteActions = NoteActions()
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
        self.noteActions = noteActions
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
                    // The system's own confirm button: one glass check. A
                    // filled circle drawn inside it sat in a second layer of
                    // glass.
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) {
                            dismiss()
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

    /// Opens on the reader's place, Apple Books style: the entry the reader is
    /// in carries a checkmark and is scrolled to the middle of the list, so a
    /// 40-chapter book does not open on chapter 1 every time.
    private var contentsList: some View {
        ScrollViewReader { proxy in
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

                                if item.isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(palette.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityAddTraits(item.isCurrent ? .isSelected : [])
                    }
                }
            }
            .listStyle(.plain)
            .allowsHitTesting(rowsAcceptTaps)
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                rowsAcceptTaps = true
            }
            // Start at the reader's place instead of scrolling to it after the
            // list appears: a list that moves after it is shown puts a
            // different row under the finger than the one the reader aimed at.
            .defaultScrollAnchor(.top)
            .onAppear {
                guard let currentOutlineID else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { proxy.scrollTo(currentOutlineID, anchor: .center) }
            }
        }
    }

    private var currentOutlineID: String? {
        outlineItems.last(where: \.isCurrent)?.id
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
                    description: Text("Select text while reading to add highlights or make flashcards.")
                )
            } else {
                ForEach(notes) { item in
                    Button {
                        onSelectNote(item)
                        dismiss()
                    } label: {
                        noteRow(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing, allowsFullSwipe: item.kind != .card) {
                        if noteActions.remove != nil {
                            Button(role: item.kind == .card ? nil : .destructive) {
                                requestRemoval(of: item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(palette.danger)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if canEdit(item) {
                            Button {
                                edit(item)
                            } label: {
                                Label(editTitle(for: item), systemImage: "square.and.pencil")
                            }
                            .tint(palette.accent)
                        }
                    }
                    .contextMenu {
                        noteMenu(item)
                    } preview: {
                        notePreview(item)
                    }
                }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(
            "Remove this card’s highlights?",
            isPresented: Binding(get: { pendingCardRemoval != nil }, set: { if !$0 { pendingCardRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingCardRemoval
        ) { item in
            Button("Remove Highlight") { noteActions.remove?(item) }
            if let deleteCard = noteActions.deleteCard {
                Button("Delete Card Too", role: .destructive) { deleteCard(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removing the highlight keeps the card in your collection. Deleting the card removes it and its review history.")
        }
        .alert(
            "Note",
            isPresented: Binding(get: { noteEditing != nil }, set: { if !$0 { noteEditing = nil } }),
            presenting: noteEditing
        ) { item in
            TextField("Note", text: $noteText, axis: .vertical)
            Button("Save") { noteActions.setNote?(item, noteText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Mark actions

    private func canEdit(_ item: NoteItem) -> Bool {
        item.kind == .highlight ? noteActions.setNote != nil : noteActions.edit != nil
    }

    private func editTitle(for item: NoteItem) -> String {
        switch item.kind {
        case .highlight: (item.note ?? "").isEmpty ? "Add Note" : "Edit Note"
        case .card, .draft: "Edit Card"
        }
    }

    /// A highlight's note is written right here; a card or draft opens its
    /// editor over the book, so the list closes first.
    private func edit(_ item: NoteItem) {
        if item.kind == .highlight {
            noteText = item.note ?? ""
            noteEditing = item
        } else {
            dismiss()
            noteActions.edit?(item)
        }
    }

    /// A card asks whether the card goes too; the rest go at once.
    private func requestRemoval(of item: NoteItem) {
        if item.kind == .card {
            pendingCardRemoval = item
        } else {
            noteActions.remove?(item)
        }
    }

    @ViewBuilder
    private func noteMenu(_ item: NoteItem) -> some View {
        Button("Go To", systemImage: "arrow.turn.down.right") {
            onSelectNote(item)
            dismiss()
        }
        if canEdit(item) {
            Button(editTitle(for: item), systemImage: "square.and.pencil") { edit(item) }
        }
        if let recolour = noteActions.recolour, noteActions.canRecolour(item) {
            Menu("Colour", systemImage: "paintpalette") {
                ForEach(PDFAnnotationColour.captureChoices) { choice in
                    Button {
                        recolour(item, choice)
                    } label: {
                        Label {
                            Text(choice.label)
                        } icon: {
                            Image(systemName: choice.hex.caseInsensitiveCompare(item.colorHex ?? "") == .orderedSame
                                  ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(choice.swiftUIColor)
                        }
                    }
                }
            }
        }
        if noteActions.remove != nil {
            Divider()
            if item.kind == .card {
                Button("Remove Highlight", systemImage: "eraser") { noteActions.remove?(item) }
                if let deleteCard = noteActions.deleteCard {
                    Button("Delete Card Too", systemImage: "trash", role: .destructive) { deleteCard(item) }
                }
            } else {
                Button(item.kind == .draft ? "Discard Draft" : "Delete Highlight", systemImage: "trash", role: .destructive) {
                    noteActions.remove?(item)
                }
            }
        }
    }

    /// The whole mark, unclipped: pictures at a readable size, every line of
    /// its passages, and its note.
    private func notePreview(_ item: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: item.colorHex))
                    .frame(width: 10, height: 10)
                Text(previewTitle(for: item))
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                if !item.pageLabel.isEmpty {
                    Text("Page \(item.pageLabel)")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            ForEach(item.images, id: \.self) { url in
                if let image = Self.image(at: url) {
                    image.resizable().scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous))
                }
            }
            if !item.quote.isEmpty {
                previewSide(item.kind == .highlight ? nil : "FRONT", item.quote)
            }
            if let secondary = item.secondary, !secondary.isEmpty {
                previewSide("BACK", secondary)
            }
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .amgiFont(.body)
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .background(palette.background)
    }

    private func previewSide(_ label: String?, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(palette.textSecondary)
            }
            Text(text)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
        }
    }

    private func previewTitle(for item: NoteItem) -> String {
        switch item.kind {
        case .highlight: "Highlight"
        case .card: "Card"
        case .draft: "Draft"
        }
    }

    /// One mark: its colour down the leading edge, then what it holds — a
    /// capture's pictures, its passage and its answer — and where it is.
    private func noteRow(_ item: NoteItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(color(for: item.colorHex))
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                if !item.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.images.prefix(3), id: \.self) { url in
                            notePicture(url)
                        }
                    }
                }

                if !item.quote.isEmpty {
                    Text(item.quote)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(4)
                }

                if let secondary = item.secondary, !secondary.isEmpty {
                    Label {
                        Text(secondary).lineLimit(3)
                    } icon: {
                        Image(systemName: "arrow.turn.down.right")
                    }
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                }

                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .amgiFont(.captionBold)
                        .foregroundStyle(palette.accent)
                }

                HStack(spacing: 6) {
                    if item.kind != .highlight {
                        Label(item.kind == .card ? "Card" : "Draft",
                              systemImage: item.kind == .card ? "rectangle.portrait.on.rectangle.portrait" : "rectangle.dashed")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(color(for: item.colorHex))
                        Text("·")
                    }
                    Text(item.pageLabel.isEmpty ? "" : "Page \(item.pageLabel)")
                }
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func notePicture(_ url: URL) -> some View {
        let shape = RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
        return Group {
            if let image = Self.image(at: url) {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 64, height: 48)
            }
        }
        .frame(maxHeight: 72)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.separator, lineWidth: 0.5))
        .accessibilityLabel("Picture")
    }

    private static func image(at url: URL) -> Image? {
        #if canImport(UIKit)
        UIImage(contentsOfFile: url.path).map(Image.init(uiImage:))
        #else
        NSImage(contentsOf: url).map(Image.init(nsImage:))
        #endif
    }

    private func color(for hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return palette.accent }
        return ReaderThemeColor.color(fromHex: hex, fallback: palette.accent)
    }
}
