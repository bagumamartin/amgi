import SwiftUI
import AmgiUI
import AmgiTheme
import AmgiCardWeb

/// Native SwiftUI renderer for allowlist-simple cards (R11). Renders the
/// side's parsed blocks on a radius-24 `AmgiCard` surface with UNIFORM
/// typography per region — no invented hierarchy:
///
/// - Front: every text block 32pt semibold serif.
/// - Back recap (blocks before the divider, i.e. the `{{FrontSide}}`
///   expansion): 22pt semibold — slightly bigger/bolder than the answer for
///   differentiation.
/// - Back answer (blocks from the divider onward): 20pt regular.
///
/// `<hr>` becomes a hairline; when the template lacks one, the split point
/// is synthesized from the front text prefix (`resolvingBackAnswerSplit`). Only
/// user-authored inline markup (`<b>/<i>` runs) adds emphasis.
///
/// Conforms to `Equatable` so `.equatable()` at the call site can skip body
/// evaluation when unrelated session fields invalidate the parent — closure
/// properties are excluded from the comparison because they are recreated
/// every render but always wrap identical behaviour.
struct NativeCardView: View, Equatable {
    let content: NativeCardContent
    let isAnswerSide: Bool
    /// Back side only: index of the first answer block (nil = no reliable
    /// split, everything renders as answer).
    let answerStartIndex: Int?
    let mediaFolder: URL?
    let onQuestionCanvasTap: (() -> Void)?
    let onTextLookup: ((String) -> Void)?

    // Nonisolated: only reads immutable Sendable stored properties, so the
    // comparison is safe off the main actor.
    nonisolated static func == (lhs: NativeCardView, rhs: NativeCardView) -> Bool {
        lhs.content == rhs.content
            && lhs.isAnswerSide == rhs.isAnswerSide
            && lhs.answerStartIndex == rhs.answerStartIndex
            && lhs.mediaFolder == rhs.mediaFolder
    }

    @Environment(\.palette) private var palette
    @Environment(\.nativeCardMinHeight) private var minCardHeight

    init(
        content: NativeCardContent,
        isAnswerSide: Bool,
        answerStartIndex: Int? = nil,
        mediaFolder: URL?,
        onQuestionCanvasTap: (() -> Void)? = nil,
        onTextLookup: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.isAnswerSide = isAnswerSide
        self.answerStartIndex = answerStartIndex
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
                VStack(spacing: AmgiSpacing.lg) {
                    ForEach(Array(content.blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, index: index)
                    }
                }
                .frame(maxWidth: .infinity)
                // Measure the NATURAL content height (the card's minHeight is
                // applied outside it), so FlipContainer can equalize both
                // sides to the taller one without a feedback loop.
                .background(heightReader)
            }
            .frame(maxWidth: .infinity, minHeight: minCardHeight, alignment: .top)
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

    @ViewBuilder
    private var heightReader: some View {
        if isAnswerSide {
            GeometryReader { geo in
                Color.clear.preference(key: BackCardNaturalHeightKey.self, value: geo.size.height)
            }
        } else {
            GeometryReader { geo in
                Color.clear.preference(key: FrontCardNaturalHeightKey.self, value: geo.size.height)
            }
        }
    }

    /// Recap = back-side blocks before the answer split.
    private func isRecap(_ index: Int) -> Bool {
        guard isAnswerSide, let answerStart = answerStartIndex else { return false }
        return index < answerStart
    }

    private func textFont(isRecap: Bool) -> Font {
        if !isAnswerSide {
            return .system(size: 32, weight: .semibold, design: .serif)
        }
        // Recap (the front-side text) stays header-like — semibold, slightly
        // smaller than the front; the answer below the hairline is the only
        // normal-weight text.
        return isRecap
            ? .system(size: 22, weight: .semibold, design: .serif)
            : .system(size: 20, weight: .regular, design: .serif)
    }

    @ViewBuilder
    private func blockView(_ block: NativeCardContent.Block, index: Int) -> some View {
        switch block {
        case .text(let attributed):
            // One `Text` rather than if/else over two `Text`s so the block
            // keeps a stable identity. Recap/answer sizing is Martin's
            // product typography; lookup is an iOS extra.
            Text(attributed)
                .font(textFont(isRecap: isRecap(index)))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.textPrimary)
            #if os(iOS)
                .contentShape(Rectangle())
                .highPriorityGesture(textLookupGesture(for: String(attributed.characters)))
            #endif
        case .image(let filename):
            #if os(iOS)
            // Decoded and downsampled off the main thread — a full-resolution
            // decode here lands squarely in the answer-reveal frame.
            DownsampledImage(
                url: mediaFolder?.appendingPathComponent(filename),
                maxPixelSize: AmgiImagePixelSize.card
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            } placeholder: {
                EmptyView()
            }
            #else
            NativeMediaImageView(filename: filename, mediaFolder: mediaFolder)
            #endif
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

/// One media image on a native card. Loads asynchronously through the shared
/// cache (decode off-main) instead of synchronously in the card's body, so a
/// flip never blocks on disk I/O or image decode.
private struct NativeMediaImageView: View {
    let filename: String
    let mediaFolder: URL?

    @State private var cgImage: CGImage?

    var body: some View {
        Group {
            if let cgImage {
                Image(decorative: cgImage, scale: 2, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            }
        }
        .task(id: filename) { await load() }
    }

    private func load() async {
        if cgImage != nil { return }
        guard let mediaFolder else { return }
        let path = mediaFolder.appendingPathComponent(filename).path

        let startedAt = Date()
        let decoded = await NativeMediaImageCache.shared.image(at: path)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        if let decoded {
            cgImage = decoded
            print("[NativeCard] image \(filename) ready in \(elapsedMs)ms")
        } else {
            print("[NativeCard] missing/unreadable media: \(filename)")
        }
    }
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
    let front = NativeCardContent.parse(html: "猫")
    let resolved = NativeCardContent
        .parse(html: "猫<hr>cat<br><i>The cat sat on the mat.</i>")
        .resolvingBackAnswerSplit(front: front)
    NativeCardView(
        content: resolved.content,
        isAnswerSide: true,
        answerStartIndex: resolved.answerStart,
        mediaFolder: nil
    )
}
#endif
