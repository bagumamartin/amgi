import AmgiTheme
import AmgiUI
import SwiftUI

/// The menu a tapped capture mark opens, at the mark.
///
/// MarginNote's excerpt popup, for Amgi's captures: recolour the capture,
/// open the card (or resume the draft), jump to the card's other passage, or
/// remove it. Removing a saved card's mark asks each time whether the card
/// goes too — the mark is Amgi's pointer into the book, the card lives in
/// the collection and syncs.
///
/// Laid over the whole reader; a tap anywhere else closes it.
struct ReaderMarkMenuLayer: View {
    @Bindable var session: ReaderCardSession

    var body: some View {
        if let menu = session.markMenu {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color(.sRGB, white: 0, opacity: 0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { session.dismissMarkMenu() }
                    ReaderMarkMenuPanel(session: session, menu: menu)
                        .id(menu.id)
                        .fixedSize()
                        .position(Self.position(for: menu.point, in: proxy.frame(in: .global)))
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .ignoresSafeArea()
        }
    }

    private static let panelSize = CGSize(width: 290, height: 116)

    /// Above the tap when there is room, below it when not, kept on screen.
    /// An unknown point puts the menu in the middle.
    private static func position(for point: CGPoint, in frame: CGRect) -> CGPoint {
        guard point != .zero else { return CGPoint(x: frame.width / 2, y: frame.height / 2) }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let halfWidth = panelSize.width / 2
        let halfHeight = panelSize.height / 2
        let gap: CGFloat = 28
        var y = local.y - gap - halfHeight
        if y - halfHeight < 60 { y = local.y + gap + halfHeight }
        let x = min(max(local.x, halfWidth + 12), frame.width - halfWidth - 12)
        return CGPoint(x: x, y: min(y, frame.height - halfHeight - 12))
    }
}

private struct ReaderMarkMenuPanel: View {
    @Bindable var session: ReaderCardSession
    let menu: ReaderMarkMenu

    @Environment(\.palette) private var palette
    @State private var confirmingRemove = false

    private static let shape = RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)

    var body: some View {
        VStack(spacing: 10) {
            colours
            Divider()
            if confirmingRemove {
                removeChoices
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                actions
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(12)
        .frame(width: 290)
        .amgiMaterial(.regular, in: Self.shape, interactive: true)
        .amgiMaterialElevation(Self.shape)
        .animation(AmgiMotion.standard, value: confirmingRemove)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu.isCard ? "Card passage" : "Draft passage")
    }

    private var colours: some View {
        HStack(spacing: 0) {
            ForEach(PDFAnnotationColour.captureChoices) { choice in
                let current = session.markMenu?.colour ?? menu.colour
                Button {
                    Task { await session.recolourMark(menu, to: choice) }
                } label: {
                    Circle()
                        .fill(choice.swiftUIColor)
                        .frame(width: 26, height: 26)
                        .overlay {
                            if choice == current {
                                Circle().strokeBorder(palette.textPrimary, lineWidth: 2).padding(-4)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(choice == current ? .isSelected : [])
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            action(menu.isCard ? "Open Card" : "Edit Card", systemImage: menu.isCard ? "rectangle.portrait.on.rectangle.portrait" : "square.and.pencil") {
                Task { await session.openMarkTarget(menu) }
            }
            if menu.hasOtherPassage {
                action("Other Passage", systemImage: "arrow.turn.down.right") {
                    session.goToOtherPassage(menu)
                }
            }
            action("Remove", systemImage: "eraser", role: .destructive) {
                if menu.isCard {
                    confirmingRemove = true
                } else {
                    Task { await session.removeMark(menu) }
                }
            }
        }
    }

    /// A card's mark: the highlight alone, or the card with it.
    private var removeChoices: some View {
        HStack(spacing: 6) {
            Button {
                confirmingRemove = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            choice("Remove Highlight", tint: palette.textPrimary) {
                Task { await session.removeMark(menu) }
            }
            .accessibilityHint("The card stays in your collection.")
            choice("Delete Card Too", tint: palette.danger) {
                Task { await session.deleteCard(menu) }
            }
            .accessibilityHint("Deletes the card from your collection, with its review history.")
        }
    }

    private func action(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: perform) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(role == .destructive ? palette.danger : palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choice(_ title: String, tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(tint.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
