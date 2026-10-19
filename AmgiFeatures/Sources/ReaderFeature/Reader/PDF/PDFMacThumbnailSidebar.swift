#if os(macOS)
import AmgiTheme
import AppKit
import PDFKit
import SwiftUI

/// What the Mac PDF reader's sidebar shows, as Preview's View menu offers it.
enum PDFMacSidebarMode: String, CaseIterable, Identifiable {
    case hidden
    case thumbnails
    case contents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden: "Hide Sidebar"
        case .thumbnails: "Thumbnails"
        case .contents: "Table of Contents"
        }
    }

    /// Preview's shortcuts: ⌥⌘1, ⌥⌘2, ⌥⌘3.
    var shortcut: KeyEquivalent {
        switch self {
        case .hidden: "1"
        case .thumbnails: "2"
        case .contents: "3"
        }
    }
}

/// Preview-style page navigator for the macOS PDF reader: page thumbnails at
/// each page's own shape on the sidebar's grey, or the document's outline.
///
/// The thumbnails used to sit in fixed portrait boxes filled white on a white
/// background, so landscape slides floated in blank space and every page
/// washed into the sidebar. They now draw at their real aspect ratio, as white
/// sheets with a shadow on the window's grey, the way Preview draws them.
struct PDFMacThumbnailSidebar: View {
    let mode: PDFMacSidebarMode
    let model: PDFReaderModel
    let currentPage: Int
    let onSelectPage: (Int) -> Void
    @Binding var thumbnailWidth: CGFloat

    static let thumbnailWidthRange: ClosedRange<CGFloat> = 72...220

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .contents:
                contentsList
            case .thumbnails, .hidden:
                thumbnailList
            }

            if mode == .thumbnails {
                sizeBar
            }
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarWidth: CGFloat {
        mode == .contents ? 260 : thumbnailWidth + 56
    }

    // MARK: - Thumbnails

    private var thumbnailList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<model.pageCount, id: \.self) { pageIndex in
                        pageThumbnail(at: pageIndex)
                            .id(pageIndex)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .onAppear {
                proxy.scrollTo(currentPage, anchor: .center)
            }
            .onChange(of: currentPage) { _, pageIndex in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(pageIndex, anchor: .center)
                }
            }
        }
    }

    /// The page's size at the sidebar's width, keeping its shape. A very tall
    /// page is held to a sensible height and narrowed instead.
    private func thumbnailSize(forPage index: Int) -> CGSize {
        var aspect: CGFloat = 1.294 // US Letter, until the page says otherwise
        if let page = model.document?.page(at: index) {
            let box = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let width = rotated ? box.height : box.width
            let height = rotated ? box.width : box.height
            if width > 0, height > 0 { aspect = height / width }
        }
        let maxHeight = thumbnailWidth * 1.5
        let height = min(thumbnailWidth * aspect, maxHeight)
        return CGSize(width: height / aspect, height: height)
    }

    private func pageThumbnail(at pageIndex: Int) -> some View {
        let isSelected = pageIndex == currentPage
        let pageLabel = model.label(forPage: pageIndex)
        let size = thumbnailSize(forPage: pageIndex)

        return Button {
            onSelectPage(pageIndex)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = model.drawThumbnail(
                        forPage: pageIndex,
                        size: CGSize(width: size.width * 2, height: size.height * 2)
                    ) {
                        Image(platformImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.white
                    }
                }
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 0.5)

                Text(pageLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(pageLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sizeBar: some View {
        HStack(spacing: 2) {
            sizeButton("minus.circle", label: "Decrease Thumbnail Size", delta: -20)
            sizeButton("plus.circle", label: "Increase Thumbnail Size", delta: 20)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }

    private func sizeButton(_ symbol: String, label: String, delta: CGFloat) -> some View {
        Button {
            let range = Self.thumbnailWidthRange
            thumbnailWidth = min(max(thumbnailWidth + delta, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Table of contents

    @ViewBuilder
    private var contentsList: some View {
        let entries = model.bookmarks
        if entries.isEmpty {
            ContentUnavailableView(
                "No Table of Contents",
                systemImage: "list.bullet.indent",
                description: Text("This document has no outline.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let currentID = PDFContentsPosition.currentEntryID(in: entries, page: currentPage)
            ScrollViewReader { proxy in
                List {
                    ForEach(entries) { entry in
                        contentsRow(entry, isCurrent: entry.id == currentID)
                            .id(entry.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let currentID { proxy.scrollTo(currentID, anchor: .center) }
                }
            }
        }
    }

    private func contentsRow(_ entry: PDFBookmark, isCurrent: Bool) -> some View {
        Button {
            if entry.hasDestination { onSelectPage(entry.pageIndex) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title)
                    .font(.system(size: 12, weight: entry.depth == 0 ? .medium : .regular))
                    .foregroundStyle(entry.hasDestination ? Color.primary : Color.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if entry.hasDestination {
                    Text(model.label(forPage: entry.pageIndex))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, CGFloat(entry.depth) * 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isCurrent
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .padding(.horizontal, 8)
                : nil
        )
        .disabled(!entry.hasDestination)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
#endif
