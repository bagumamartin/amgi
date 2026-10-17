import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The waiting card, docked above the page — Mail's minimised draft, for
/// flashcards.
///
/// It stays put while you turn pages, jump chapters, or search, because the
/// answer it is waiting for may be anywhere in the book. Several drafts stack
/// behind it, each showing a tab with its front.
///
/// Three ways to fill the back of any card in the stack, fastest first:
/// - drag a selection onto the dock — the stack fans out into one row per
///   card, and the row it is dropped on takes it as its back;
/// - tap a card's tab to bring it to the front, then "Add to Back" in the
///   selection menu, which names the card it fills;
/// - "Other Cards" in the selection menu, one level down.
///
/// A card with both sides filled stays here, ready, so either side can still
/// take more: its check saves it, and so does starting the next card or
/// leaving the book. Its colour — the capture's category — runs down its
/// leading edge and is changed from the dot beside the check.
///
/// Gestures on the front card: tap opens it, swipe down saves it (once both
/// sides are filled), swipe sideways switches drafts. Everything is also in
/// the context menu and the accessibility actions, so none of it depends on a
/// gesture.
struct ReaderCardDock: View {
    let drafts: [ReaderCardDraft]
    let onOpen: (UUID) -> Void
    let onSave: (UUID) -> Void
    let onCycle: (_ forward: Bool) -> Void
    let onDiscard: (UUID) -> Void
    let onGoTo: (ReaderSourceAnchor) -> Void
    /// A tab was tapped: make that draft the one "Add to Back" fills.
    let onBringToFront: (UUID) -> Void
    /// Text was dropped on a draft. The host turns it into a clip on its back.
    let onDrop: (_ text: String, _ draftID: UUID) -> Void
    /// A draft's colour was changed.
    var onRecolour: (UUID, PDFAnnotationColour) -> Void = { _, _ in }
    /// Where a draft's picture is, so a side made of one can show it.
    var imageURL: (String) -> URL? = { _ in nil }

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var rejectedSave = 0
    /// A drag is over the dock: show every draft as a drop row.
    @State private var isDropTargeted = false
    /// The row the drag is over while fanned out.
    @State private var hoveredDraftID: UUID?

    /// The review card's radius: a docked draft *is* a card.
    private static let shape = RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
    /// Tabs shown behind the front card; any further drafts are counted.
    private static let visibleTabs = 2
    /// How much of each tab shows above the card in front of it.
    private static let tabReveal: CGFloat = 26
    /// Drop rows while fanned out; fixed height so a drop location maps to a
    /// row without measuring.
    static let dropRowHeight: CGFloat = 52
    static let dropRowSpacing: CGFloat = 6
    static let maxDropRows = 6

    var body: some View {
        if let front = drafts.first {
            Group {
                if isDropTargeted {
                    dropRows
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                } else {
                    stack(front)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 460)
            .onDrop(of: [.plainText, .utf8PlainText, .text], delegate: DockDropDelegate(
                drafts: Array(drafts.prefix(Self.maxDropRows)),
                isTargeted: $isDropTargeted,
                hoveredDraftID: $hoveredDraftID,
                onDrop: onDrop
            ))
            .animation(reduceMotion ? nil : AmgiMotion.standard, value: isDropTargeted)
            .sensoryFeedback(.warning, trigger: rejectedSave)
            .sensoryFeedback(.selection, trigger: hoveredDraftID)
        }
    }

    // MARK: - Stack

    private func stack(_ front: ReaderCardDraft) -> some View {
        let behind = Array(drafts.dropFirst().prefix(Self.visibleTabs))
        let hidden = drafts.count - 1 - behind.count
        return VStack(spacing: -12) {
            // Farthest first, so the nearest tab sits right above the card.
            ForEach(Array(behind.enumerated()).reversed(), id: \.element.id) { index, draft in
                tab(draft, depth: index + 1, extra: index == behind.count - 1 ? hidden : 0)
            }
            card(front)
                .id(front.id)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .scale(scale: 0.9).combined(with: .opacity)
                ))
        }
    }

    /// A draft behind the front one, showing just enough to be recognised and
    /// tapped. A tap brings it to the front — the card "Add to Back" fills.
    private func tab(_ draft: ReaderCardDraft, depth: Int, extra: Int) -> some View {
        let tabShape = UnevenRoundedRectangle(
            topLeadingRadius: AmgiRadius.card,
            topTrailingRadius: AmgiRadius.card,
            style: .continuous
        )
        return Button { onBringToFront(draft.id) } label: {
            HStack(spacing: 8) {
                Text(ReaderSourceAnchor.normalize(draft.front).isEmpty ? "Untitled card" : draft.shortTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if extra > 0 {
                    Text("+\(extra)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.tabReveal, alignment: .center)
            .padding(.bottom, 12)
            .contentShape(tabShape)
        }
        .buttonStyle(.plain)
        .amgiMaterial(.regular, in: tabShape)
        .padding(.horizontal, CGFloat(depth) * 10)
        .opacity(1 - Double(depth - 1) * 0.2)
        .accessibilityLabel("Switch to card: \(draft.shortTitle)")
        .accessibilityHint("Makes it the card Add to Back fills.")
    }

    // MARK: - Drop rows

    /// Every waiting card as a drop target, shown while a drag is over the
    /// dock. The row under the finger lights up; letting go there fills that
    /// card's back.
    private var dropRows: some View {
        VStack(spacing: Self.dropRowSpacing) {
            ForEach(drafts.prefix(Self.maxDropRows)) { draft in
                dropRow(draft, isHovered: hoveredDraftID == draft.id)
            }
        }
    }

    private func dropRow(_ draft: ReaderCardDraft, isHovered: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isHovered ? "arrow.down.circle.fill" : ReaderSelectionMenu.addToBackImage)
                .font(.system(size: 18))
                .foregroundStyle(isHovered ? palette.accent : palette.textSecondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.shortTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(draft.hasContent(.back) ? "Add to the back" : "Drop the answer here")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.dropRowHeight)
        .amgiMaterial(.regular, in: Self.shape)
        .overlay {
            Self.shape.strokeBorder(palette.accent, lineWidth: isHovered ? 2 : 0)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(AmgiMotion.standard, value: isHovered)
    }

    private func colour(of draft: ReaderCardDraft) -> PDFAnnotationColour {
        PDFAnnotationColour(captureHex: draft.colorHex) ?? .captureDefault
    }

    private func card(_ draft: ReaderCardDraft) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                sideRow("Front", draft, .front, placeholder: "Select the question…")
                sideRow("Back", draft, .back, placeholder: "Select the answer…")
            }
            Spacer(minLength: 0)
            trailingControl(draft)
        }
        // The capture's colour, down the card's leading edge: the same colour
        // its passages are marked in on the page.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(colour(of: draft).swiftUIColor)
                .frame(width: 4)
                .padding(.vertical, 12)
                .padding(.leading, -8)
                .accessibilityHidden(true)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .contentShape(Self.shape)
        .amgiMaterial(.regular, in: Self.shape, interactive: true)
        .amgiMaterialElevation(Self.shape)
        .offset(x: dragOffset.width, y: max(0, dragOffset.height))
        .rotationEffect(.degrees(Double(dragOffset.width) / 40))
        .onTapGesture { onOpen(draft.id) }
        .gesture(dragGesture(for: draft))
        .contextMenu { menu(for: draft) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(draft))
        .accessibilityHint("Opens the card. Swipe down to save it.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(draft.id) }
        .accessibilityAction(named: "Save Card") { save(draft) }
        .accessibilityAction(named: "Next Draft") { onCycle(true) }
        .accessibilityAction(named: "Discard Draft") { onDiscard(draft.id) }
    }

    private func sideRow(
        _ label: String,
        _ draft: ReaderCardDraft,
        _ side: ReaderCardDraft.Side,
        placeholder: String
    ) -> some View {
        // A saved card back in the dock shows what it already says, with
        // anything being added after it.
        let existing = draft.addsToExistingCard
            ? ReaderSourceAnchor.normalize((side == .front ? draft.existingFront : draft.existingBack) ?? "")
            : ""
        let added = ReaderSourceAnchor.normalize(draft.text(side))
        let trimmed = [existing, added].filter { !$0.isEmpty }.joined(separator: " ")
        let images = draft.images(side)
        let isEmpty = trimmed.isEmpty && images.isEmpty
        return HStack(alignment: .center, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(palette.textSecondary)
                .frame(width: 40, alignment: .leading)
            // Pictures first: on a side that has both, the picture is what
            // the side is, and its caption can truncate.
            ForEach(images.prefix(3), id: \.self) { name in
                thumbnail(name)
            }
            if images.count > 3 {
                Text("+\(images.count - 3)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
            }
            if !trimmed.isEmpty || isEmpty {
                Text(isEmpty ? placeholder : trimmed)
                    .font(.system(size: 14, weight: isEmpty ? .regular : .medium))
                    .italic(isEmpty)
                    .foregroundStyle(isEmpty ? palette.textSecondary.opacity(0.8) : palette.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .frame(minHeight: 20)
    }

    /// A captured area, small enough to sit in a side's row.
    private func thumbnail(_ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: AmgiRadius.control / 2, style: .continuous)
        return Group {
            if let url = imageURL(name), let image = ReaderCardDock.image(at: url) {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(palette.textSecondary)
            }
        }
        .frame(width: 30, height: 20)
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

    /// The colours, as a menu: on the dot beside the check, and in the card's
    /// context menu.
    @ViewBuilder
    private func colourChoices(for draft: ReaderCardDraft) -> some View {
        let current = colour(of: draft)
        ForEach(PDFAnnotationColour.captureChoices) { choice in
            Button {
                onRecolour(draft.id, choice)
            } label: {
                Label {
                    Text(choice.label)
                } icon: {
                    Image(systemName: choice == current ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(choice.swiftUIColor)
                }
            }
        }
    }

    private func colourButton(_ draft: ReaderCardDraft) -> some View {
        Menu {
            colourChoices(for: draft)
        } label: {
            Circle()
                .fill(colour(of: draft).swiftUIColor)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(palette.textPrimary.opacity(0.15), lineWidth: 1))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Colour: \(colour(of: draft).label)")
    }

    private func trailingControl(_ draft: ReaderCardDraft) -> some View {
        HStack(spacing: 2) {
            colourButton(draft)
            if draft.isComplete || draft.addsToExistingCard {
                // Ready: both sides are filled. It waits here for more until
                // this is tapped, the next card starts, or the book closes.
                Button { save(draft) } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(palette.accent)
                        .symbolEffect(.bounce, value: draft.isComplete)
                }
                .buttonStyle(.pressScale)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(draft.addsToExistingCard && !draft.isComplete ? "Done" : "Save Card")
                .accessibilityHint(draft.addsToExistingCard
                    ? (draft.isComplete ? "Adds what you selected to the card." : "Puts the card away.")
                    : "Both sides are filled. You can still add to either side first.")
            } else if drafts.count > 1 {
                Text(drafts.count, format: .number)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Circle().fill(palette.separator.opacity(0.6)))
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : AmgiMotion.standard, value: draft.isComplete)
    }

    @ViewBuilder
    private func menu(for draft: ReaderCardDraft) -> some View {
        if draft.isComplete {
            Button("Save Card", systemImage: "checkmark.circle") { save(draft) }
        }
        Button("Edit Card", systemImage: "square.and.pencil") { onOpen(draft.id) }
        Menu("Colour", systemImage: "paintpalette") { colourChoices(for: draft) }
        if let anchor = draft.frontClips.first?.anchor {
            Button("Go to Front", systemImage: ReaderSelectionMenu.addToFrontImage) { onGoTo(anchor) }
        }
        if let anchor = draft.backClips.first?.anchor {
            Button("Go to Back", systemImage: ReaderSelectionMenu.addToBackImage) { onGoTo(anchor) }
        }
        if drafts.count > 1 {
            Button("Next Draft", systemImage: "rectangle.stack") { onCycle(true) }
        }
        Divider()
        Button("Discard Draft", systemImage: "trash", role: .destructive) { onDiscard(draft.id) }
    }

    private func dragGesture(for draft: ReaderCardDraft) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let horizontal = drafts.count > 1 ? value.translation.width : value.translation.width * 0.15
                dragOffset = CGSize(width: horizontal, height: value.translation.height * 0.6)
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                withAnimation(AmgiMotion.momentum) {
                    dragOffset = .zero
                    if abs(dx) > 60, abs(dx) > abs(dy), drafts.count > 1 {
                        onCycle(dx < 0)
                    } else if dy > 44, dy > abs(dx) {
                        save(draft)
                    }
                }
            }
    }

    private func save(_ draft: ReaderCardDraft) {
        if draft.isComplete {
            onSave(draft.id)
        } else if draft.addsToExistingCard {
            // Nothing was added: done means put the card away.
            onDiscard(draft.id)
        } else {
            rejectedSave += 1
            onOpen(draft.id)
        }
    }

    private func accessibilityLabel(_ draft: ReaderCardDraft) -> String {
        func describe(_ side: ReaderCardDraft.Side, empty: String) -> String {
            guard draft.hasContent(side) else { return empty }
            let pictures = draft.images(side).count
            let text = ReaderSourceAnchor.normalize(draft.text(side))
            let picture = pictures == 0 ? "" : (pictures == 1 ? "a picture" : "\(pictures) pictures")
            return [text, picture].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        let front = describe(.front, empty: "empty")
        let back = describe(.back, empty: "waiting for an answer")
        let ready = draft.isComplete ? ", ready to save" : ""
        let stack = drafts.count > 1 ? ", 1 of \(drafts.count) unfinished cards" : ""
        return "Card draft, \(colour(of: draft).label). Front: \(front). Back: \(back)\(ready)\(stack)"
    }
}

/// Fans the dock out while a drag is over it and maps the drop to a row.
///
/// One delegate on the whole dock, rather than a drop target per row: nested
/// targets hand the drag back and forth as the finger crosses them, and the
/// outer one would collapse the fan the moment an inner one took over.
private struct DockDropDelegate: DropDelegate {
    let drafts: [ReaderCardDraft]
    @Binding var isTargeted: Bool
    @Binding var hoveredDraftID: UUID?
    let onDrop: (_ text: String, _ draftID: UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !drafts.isEmpty && info.hasItemsConforming(to: [.plainText, .utf8PlainText, .text])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        hoveredDraftID = target(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoveredDraftID = target(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        hoveredDraftID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let draftID = target(at: info.location) ?? drafts.first?.id
        isTargeted = false
        hoveredDraftID = nil
        guard let draftID,
              let provider = info.itemProviders(for: [.plainText, .utf8PlainText, .text]).first
        else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            Task { @MainActor in onDrop(text, draftID) }
        }
        return true
    }

    /// The row under `location`. Before the fan has laid out, the dock is the
    /// collapsed stack, and anything over it means the front card.
    private func target(at location: CGPoint) -> UUID? {
        guard isTargeted, drafts.count > 1 else { return drafts.first?.id }
        let pitch = ReaderCardDock.dropRowHeight + ReaderCardDock.dropRowSpacing
        let index = min(max(Int(location.y / pitch), 0), drafts.count - 1)
        return drafts[index].id
    }
}

/// "Added to Spanish · Undo", floating over the page.
struct ReaderCardToastView: View {
    let toast: ReaderCardToast
    let onUndo: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(palette.accent)
            Text(toast.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            if toast.undo != nil {
                Button("Undo", action: onUndo)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo") { onUndo() }
    }
}
