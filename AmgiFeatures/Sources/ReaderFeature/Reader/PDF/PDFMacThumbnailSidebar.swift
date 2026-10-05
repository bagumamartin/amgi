#if os(macOS)
import AmgiTheme
import SwiftUI

/// Preview-style page navigator for the macOS PDF reader.
///
/// It virtualizes the document's full page list and scrolls the active page
/// into view as the PDF canvas advances, while thumbnail taps use the same
/// reader navigation state as the iPhone scrubber.
struct PDFMacThumbnailSidebar: View {
    let model: PDFReaderModel
    let currentPage: Int
    let onSelectPage: (Int) -> Void
    @Binding var thumbnailWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<model.pageCount, id: \.self) { pageIndex in
                            pageThumbnail(at: pageIndex)
                                .id(pageIndex)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
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

            Divider()

            HStack {
                Button {
                    thumbnailWidth = min(thumbnailWidth + 12, 228)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Increase Thumbnail Size")
                .accessibilityLabel("Increase Thumbnail Size")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: thumbnailWidth + 74)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func pageThumbnail(at pageIndex: Int) -> some View {
        let isSelected = pageIndex == currentPage
        let pageLabel = model.label(forPage: pageIndex)

        return Button {
            onSelectPage(pageIndex)
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let image = model.thumbnail(
                        forPage: pageIndex,
                        size: CGSize(width: thumbnailWidth * 2, height: thumbnailWidth * 2.64)
                    ) {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(.white)
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                            }
                    }
                }
                .frame(width: thumbnailWidth, height: thumbnailWidth * 1.32)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.black.opacity(0.12), lineWidth: 0.5)
                }

                Text(pageLabel)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.accentColor.opacity(0.32))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(pageLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
