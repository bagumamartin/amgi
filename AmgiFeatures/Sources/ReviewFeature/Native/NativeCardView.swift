import SwiftUI
import AmgiAppCore
import AmgiUI
import AmgiTheme
import AmgiCardWeb
#if os(macOS)
import AppKit
#endif

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
/// identities are excluded because they are recreated every render. Whether
/// an interaction is available is still compared, so preference/answer-state
/// changes cannot leave a stale gesture installed.
struct NativeCardView: View, Equatable {
    let content: NativeCardContent
    let isAnswerSide: Bool
    /// Back side only: index of the first answer block (nil = no reliable
    /// split, everything renders as answer).
    let answerStartIndex: Int?
    let mediaFolder: URL?
    let onQuestionCanvasTap: (() -> Void)?
    let onTextLookup: ((String) -> Void)?
    private let hasQuestionCanvasTap: Bool
    private let hasTextLookup: Bool

    // Nonisolated: only reads immutable Sendable stored properties, so the
    // comparison is safe off the main actor.
    nonisolated static func == (lhs: NativeCardView, rhs: NativeCardView) -> Bool {
        lhs.content == rhs.content
            && lhs.isAnswerSide == rhs.isAnswerSide
            && lhs.answerStartIndex == rhs.answerStartIndex
            && lhs.mediaFolder == rhs.mediaFolder
            && lhs.hasQuestionCanvasTap == rhs.hasQuestionCanvasTap
            && lhs.hasTextLookup == rhs.hasTextLookup
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
        self.hasQuestionCanvasTap = onQuestionCanvasTap != nil
        self.hasTextLookup = onTextLookup != nil
    }

    var body: some View {
        ScrollView {
            AmgiCard(
                background: .surface,
                cornerRadius: AmgiRadius.card,
                contentInsets: EdgeInsets(top: 40, leading: 24, bottom: 40, trailing: 24)
            ) {
                ZStack {
                    #if os(macOS)
                    // Bottom-most hit target: text and images consume clicks
                    // for selection / reveal respectively, while padding and
                    // empty card space reveal the answer on click.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onQuestionCanvasTap?() }
                    #endif

                    VStack(spacing: AmgiSpacing.lg) {
                        ForEach(Array(content.blocks.enumerated()), id: \.offset) { index, block in
                            blockView(block, index: index)
                        }
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
        case .text(let attributed, let alignment):
            let textAlignment: TextAlignment = switch alignment {
            case .left: .leading
            case .center: .center
            case .right: .trailing
            }
            let frameAlignment: Alignment = switch alignment {
            case .left: .leading
            case .center: .center
            case .right: .trailing
            }
            Text(attributed)
                .font(textFont(isRecap: isRecap(index)))
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .foregroundStyle(palette.textPrimary)
            #if os(iOS)
                .contentShape(Rectangle())
                .highPriorityGesture(textLookupGesture(for: String(attributed.characters)))
            #elseif os(macOS)
                // macOS deliberately separates selection from card actions:
                // text is selectable/copyable, right-click offers app lookup,
                // and only non-text card space/images click-to-reveal.
                .textSelection(.enabled)
                .contextMenu {
                    if !isAnswerSide, onTextLookup != nil {
                        Button("\(L10n.text("Look Up")) “\(macLookupPreview(for: String(attributed.characters)))”") {
                            onTextLookup?(String(attributed.characters))
                        }
                        Divider()
                    }
                    Button(L10n.text("Copy")) {
                        copyToPasteboard(String(attributed.characters))
                    }
                }
            #endif
        case .image(let filename):
            let url = mediaFolder?.appendingPathComponent(NativeCardContent.mediaFilename(from: filename))
            #if os(iOS)
            Group {
                DownsampledImage(
                    url: url,
                    maxPixelSize: AmgiImagePixelSize.card
                ) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
                } placeholder: {
                    RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                        .fill(palette.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                                .strokeBorder(palette.separator, lineWidth: 1)
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(4 / 3, contentMode: .fit)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(imageAccessibilityLabel(for: filename))
            #else
            Group {
                NativeMediaImageView(
                    filename: NativeCardContent.mediaFilename(from: filename),
                    mediaFolder: mediaFolder,
                    accessibilityLabel: imageAccessibilityLabel(for: filename)
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(imageAccessibilityLabel(for: filename))
            .contentShape(Rectangle())
            .onTapGesture { onQuestionCanvasTap?() }
            #endif
        case .divider:
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    /// Native parsing retains the media filename rather than HTML `alt`.
    /// Turn that stable, authored clue into an honest accessibility label
    /// instead of publishing a decorative image with no description at all.
    static func imageAccessibilityLabel(for filename: String, isAnswerSide: Bool = false) -> String {
        let role = isAnswerSide ? L10n.text("Answer card image") : L10n.text("Question card image")
        let filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { return role }
        var stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        while stem.hasPrefix(".") { stem.removeFirst() }
        let description = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return description.isEmpty ? role : "\(role): \(description)"
    }

    private func imageAccessibilityLabel(for filename: String) -> String {
        Self.imageAccessibilityLabel(for: filename, isAnswerSide: isAnswerSide)
    }

    #if os(macOS)
    private func macLookupPreview(for text: String) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if compact.count <= 28 { return compact }
        return String(compact.prefix(28)) + "…"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    #endif

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
    let accessibilityLabel: String

    @State private var cgImage: CGImage?
    @State private var imageUnavailable = false
    @Environment(\.palette) private var palette

    private var mediaPath: String? {
        mediaFolder?.appendingPathComponent(filename).path
    }

    var body: some View {
        Group {
            if let cgImage {
                Image(decorative: cgImage, scale: 2, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            } else if imageUnavailable {
                Label(L10n.text("Image unavailable"), systemImage: "photo")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .task(id: mediaPath) { await load() }
    }

    private func load() async {
        cgImage = nil
        imageUnavailable = false
        guard let path = mediaPath else { return }

        // Media sync may still be writing the file when a review card appears.
        // Avoid asking ImageIO to open a path that does not exist, and retry
        // while this card remains on screen so the image can appear later.
        while !Task.isCancelled {
            if FileManager.default.fileExists(atPath: path) {
                if let decoded = await NativeMediaImageCache.shared.image(at: path) {
                    guard !Task.isCancelled else { return }
                    cgImage = decoded
                    return
                }
            }
            imageUnavailable = true
            try? await Task.sleep(for: .seconds(2))
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
