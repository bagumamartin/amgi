import AmgiTheme
import AmgiUI
import AmgiReader
import AmgiReaderEPUB
import SwiftUI

struct AllBooksCell: View {
    let item: BookCellItem
    let book: ReaderBook?
    let progress: ReaderProgressCoordinator
    let coverTransition: Namespace.ID
    var onRepair: ((String, ReaderBookRepair) -> Void)? = nil
    /// The library actions this book offers. Nil leaves only Book Details.
    var actions: BookMenuActions? = nil

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            coverButton
                .frame(maxWidth: .infinity, alignment: .bottom)

            metadataBar
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.repair?.title ?? (item.author ?? ""))
        .accessibilityHint(item.repair == nil ? "" : "Double tap to repair this book.")
    }

    @ViewBuilder
    private var coverButton: some View {
        if let repair = item.repair, let onRepair {
            Button {
                onRepair(item.id, repair)
            } label: {
                coverView
            }
            .buttonStyle(.pressScale)
        } else if let book {
            NavigationLink {
                ReaderOpenView(book: book, progress: progress)
                    #if os(iOS)
                    .navigationTransition(.zoom(sourceID: item.id, in: coverTransition))
                    #endif
            } label: {
                coverView
                    .contextMenu { bookMenu }
            }
            .buttonStyle(.pressScale)
            #if os(iOS)
            .matchedTransitionSource(id: item.id, in: coverTransition)
            #endif
        } else {
            coverView
        }
    }

    private var coverView: some View {
        BookCoverView(
            coverArt: item.coverArt,
            title: item.title,
            surname: item.surname,
            seed: item.id
        )
        // Apple Books layout: the cover keeps its own shape and sits on the
        // row's bottom baseline. The chrome goes on the fitted art and the
        // height cap outside it; the other way round, the flexible frame grew
        // to the grid's offered height and the border traced empty space.
        .bookCoverChrome()
        .frame(maxHeight: 260, alignment: .bottom)
    }

    private var metadataBar: some View {
        HStack(alignment: .center, spacing: 4) {
            if let repair = item.repair {
                repairIndicator(repair)
            } else if let progressVal = item.progress, progressVal > 0 {
                if progressVal >= 1.0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                } else {
                    Text("\(Int((progressVal * 100).rounded()))%")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                }
            } else {
                Text("NEW")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue))
            }

            Spacer(minLength: 4)

            Menu { bookMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .frame(height: 24)
    }

    private var bookMenu: some View {
        BookMenuContent(
            book: book,
            progress: progress,
            repair: item.repair,
            onRepair: item.repair.flatMap { repair in onRepair.map { handler in { handler(item.id, repair) } } },
            actions: actions
        )
    }

    @ViewBuilder
    private func repairIndicator(_ repair: ReaderBookRepair) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(palette.danger)
            Text("Issue")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.danger)
        }
    }
}

#if DEBUG
private struct AllBooksCellPreview: View {
    @Namespace private var transition
    let item: BookCellItem

    var body: some View {
        AllBooksCell(
            item: item,
            book: nil,
            progress: ReaderProgressCoordinator(),
            coverTransition: transition
        )
        .frame(width: 170)
        .padding()
    }
}

#Preview {
    AllBooksCellPreview(
        item: BookCellItem(
            id: "preview-2",
            title: "Don Quijote",
            author: "Miguel de Cervantes",
            surname: "Cervantes",
            coverArt: .none,
            progress: 0.35,
            repair: nil
        )
    )
}

#Preview("Needing repair") {
    AllBooksCellPreview(
        item: BookCellItem(
            id: "preview-3",
            title: "Broken Book",
            author: nil,
            surname: nil,
            coverArt: .none,
            progress: nil,
            repair: ReaderBookRepair(
                fault: .sourceMissing,
                detail: "The stored EPUB for this book is missing on disk."
            )
        )
    )
}
#endif

/// What a book's menu can do. Built by the grid from the library model;
/// each nil hides its item (Anki-deck books, for example, can't be shared,
/// renamed or removed from here).
struct BookMenuActions {
    var shareFile: BookShareFile?
    var isFinished = false
    var hasStarted = false
    var onAddToCollection: (() -> Void)?
    var onSetFinished: ((Bool) -> Void)?
    var onRename: (() -> Void)?
    /// Continue cards only: hide the book from Continue until it is read again.
    var onRemoveFromContinue: (() -> Void)?
    var onRemove: (() -> Void)?
}
