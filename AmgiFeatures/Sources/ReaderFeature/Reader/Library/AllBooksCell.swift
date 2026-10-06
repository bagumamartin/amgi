import AmgiTheme
import AmgiReader
import AmgiReaderEPUB
import SwiftUI

struct AllBooksCell: View {
    let item: BookCellItem
    let book: ReaderBook?
    let progress: ReaderProgressCoordinator
    let coverTransition: Namespace.ID
    var onRepair: ((String, ReaderBookRepair) -> Void)? = nil

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
                    .contextMenu {
                        NavigationLink {
                            ReaderBookDetailView(book: book, progress: progress)
                        } label: {
                            Label("Book Details & Chapters", systemImage: "info.circle")
                        }
                    }
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
        .frame(maxHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 3)
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

            Menu {
                if let repair = item.repair, let onRepair {
                    Button {
                        onRepair(item.id, repair)
                    } label: {
                        Label("Repair Book…", systemImage: "wrench.and.screwdriver")
                    }
                }
                if let book {
                    NavigationLink {
                        ReaderBookDetailView(book: book, progress: progress)
                    } label: {
                        Label("Book Details & Chapters", systemImage: "info.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .frame(height: 24)
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
