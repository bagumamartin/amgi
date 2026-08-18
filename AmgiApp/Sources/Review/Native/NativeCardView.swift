import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AmgiUI
import AmgiTheme
import AmgiCardWeb

/// Native SwiftUI renderer for allowlist-simple cards (R11). Renders the
/// side's parsed blocks on a radius-24 `AmgiCard` surface: the first text
/// block is the serif headword (large on the front, reduced on the back —
/// Anki back HTML already contains `{{FrontSide}}` plus an `<hr>` divider),
/// remaining text blocks are body copy, `<hr>` becomes a hairline.
struct NativeCardView: View {
    let content: NativeCardContent
    let isAnswerSide: Bool
    let mediaFolder: URL?
    let onQuestionCanvasTap: (() -> Void)?
    let onTextLookup: ((String) -> Void)?

    @Environment(\.palette) private var palette

    init(
        content: NativeCardContent,
        isAnswerSide: Bool,
        mediaFolder: URL?,
        onQuestionCanvasTap: (() -> Void)? = nil,
        onTextLookup: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.isAnswerSide = isAnswerSide
        self.mediaFolder = mediaFolder
        self.onQuestionCanvasTap = onQuestionCanvasTap
        self.onTextLookup = onTextLookup
    }

    var body: some View {
        ScrollView {
            AmgiCard(
                background: .surface,
                cornerRadius: AmgiRadius.card,
                contentInsets: EdgeInsets(top: 40, leading: 24, bottom: 40, trailing: 24)
            ) {
                ZStack {
                    VStack(spacing: AmgiSpacing.lg) {
                        ForEach(Array(content.blocks.enumerated()), id: \.offset) { index, block in
                            blockView(block, isFirst: index == firstTextIndex)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, 8)
        }
        // The review canvas is deliberately larger than a short native card.
        // Own the gesture here, rather than on the card's intrinsic surface,
        // so its padding and the remaining canvas reveal too.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isAnswerSide else { return }
            onQuestionCanvasTap?()
        }
        #endif
    }

    private var firstTextIndex: Int? {
        content.blocks.firstIndex {
            if case .text = $0 { return true }
            return false
        }
    }

    private func mediaImage(_ filename: String) -> Image? {
        guard let mediaFolder else { return nil }
        let path = mediaFolder.appendingPathComponent(filename).path
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    @ViewBuilder
    private func blockView(_ block: NativeCardContent.Block, isFirst: Bool) -> some View {
        switch block {
        case .text(let attributed):
            let font: Font = isFirst
                ? .system(size: isAnswerSide ? 34 : 48, weight: .semibold, design: .serif)
                : .system(size: 20, design: .serif)
            Text(attributed)
                .font(font)
                .minimumScaleFactor(isFirst ? 0.5 : 1)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.textPrimary)
            #if os(iOS)
            .contentShape(Rectangle())
            .highPriorityGesture(textLookupGesture(for: String(attributed.characters)))
            #endif
        case .image(let filename):
            if let image = mediaImage(filename) {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            }
        case .divider:
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    #if os(iOS)
    private func textLookupGesture(for text: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
            .onEnded { _ in
            guard !isAnswerSide else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            onTextLookup?(text)
        }
    }
    #endif
}

#if DEBUG
#Preview("Front") {
    NativeCardView(
        content: .parse(html: "猫"),
        isAnswerSide: false,
        mediaFolder: nil
    )
}

#Preview("Back") {
    NativeCardView(
        content: .parse(html: "猫<hr>cat<br><i>The cat sat on the mat.</i>"),
        isAnswerSide: true,
        mediaFolder: nil
    )
}
#endif
