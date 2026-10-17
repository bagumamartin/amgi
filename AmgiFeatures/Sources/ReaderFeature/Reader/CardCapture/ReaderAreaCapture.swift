import AmgiTheme
import AmgiUI
import SwiftUI

/// How a touch on the page takes something for a card: by selecting text, or
/// by drawing a box around an area — a diagram, a table, a formula, anything
/// whose arrangement matters more than its words.
enum ReaderCaptureMode: String, Sendable {
    case text
    case area

    var systemImage: String {
        switch self {
        case .text: "character.cursor.ibeam"
        case .area: "viewfinder"
        }
    }

    var title: String {
        switch self {
        case .text: "Select Text"
        case .area: "Select Area"
        }
    }
}

/// What to do with an area once it is drawn.
enum ReaderAreaAction: Sendable {
    case newCard
    case front
    case back
}

/// The capture tool, in the reader's chrome: a tap switches between text and
/// area selection; a long press picks the colour new captures take. The
/// icon alone shows the mode; the colour shows on the card being made.
struct ReaderCaptureModeButton: View {
    @Binding var mode: ReaderCaptureMode
    let colour: PDFAnnotationColour
    let onColour: (PDFAnnotationColour) -> Void
    var size: CGFloat = 44
    /// Inline sits among other icons in a toolbar capsule; the default is a
    /// free-standing round control like the reader's other chrome buttons.
    var inline = false

    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            Section("Colour for New Captures") {
                ForEach(PDFAnnotationColour.captureChoices) { choice in
                    Button {
                        onColour(choice)
                    } label: {
                        Label {
                            Text(choice.label)
                        } icon: {
                            Image(systemName: choice == colour ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(choice.swiftUIColor)
                        }
                    }
                }
            }
            Section {
                Button(mode == .area ? ReaderCaptureMode.text.title : ReaderCaptureMode.area.title,
                       systemImage: mode == .area ? ReaderCaptureMode.text.systemImage : ReaderCaptureMode.area.systemImage) {
                    toggle()
                }
            }
        } label: {
            if inline {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(mode == .area ? palette.accent : palette.textPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(mode == .area ? palette.accent : palette.textPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: size, height: size)
                    .amgiMaterial(.regular, in: Circle(), interactive: true)
                    .amgiMaterialElevation(Circle())
            }
        } primaryAction: {
            toggle()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .area ? "Area selection, on" : "Text selection")
        .accessibilityValue("Captures in \(colour.label)")
        .accessibilityHint("Switches between selecting text and selecting an area. Touch and hold to choose the colour.")
    }

    private func toggle() {
        withAnimation(AmgiMotion.standard) {
            mode = mode == .area ? .text : .area
        }
    }
}

/// The surface laid over the page while area selection is on.
///
/// Drag anywhere to draw a box; drag inside it to move it, or by a corner to
/// resize it. The bar beside the box sends it to a card. Area selection stays
/// on until the capture tool is tapped again — capturing several figures in a
/// row is the common case — and a tap with no box still shows and hides the
/// reader's chrome, where that tool is.
struct ReaderAreaCaptureOverlay: View {
    let colour: PDFAnnotationColour
    /// The docked card "Front" and "Back" add to, if there is one.
    let targetTitle: String?
    let onAction: (ReaderAreaAction, CGRect) -> Void
    let onTap: () -> Void

    @Environment(\.palette) private var palette
    @State private var box: CGRect?
    @State private var manipulation: Manipulation?
    @State private var busy = false

    private enum Manipulation: Equatable {
        case drawing(origin: CGPoint)
        case moving(start: CGRect)
        case resizing(corner: Corner, start: CGRect)
    }

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    private static let handleSize: CGFloat = 22
    private static let minimumSide: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                // Catches every touch on the page while the mode is on.
                Color(.sRGB, white: 0, opacity: 0.001)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: bounds))
                    .onTapGesture {
                        if box != nil { box = nil } else { onTap() }
                    }

                if let box {
                    dimming(around: box, in: bounds)
                        .allowsHitTesting(false)
                    frame(for: box)
                        .allowsHitTesting(false)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle
                            .position(point(of: corner, in: box))
                            .allowsHitTesting(false)
                    }
                    if manipulation == nil {
                        actionBar
                            .position(barPosition(for: box, in: bounds))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .animation(AmgiMotion.standard, value: manipulation == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Area selection")
    }

    // MARK: - Drawing

    private func dragGesture(in bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if manipulation == nil { manipulation = begin(at: value.startLocation) }
                guard let manipulation else { return }
                let translation = value.translation
                switch manipulation {
                case .drawing(let origin):
                    let end = clamp(value.location, to: bounds)
                    box = CGRect(
                        x: min(origin.x, end.x), y: min(origin.y, end.y),
                        width: abs(end.x - origin.x), height: abs(end.y - origin.y)
                    )
                case .moving(let start):
                    var moved = start.offsetBy(dx: translation.width, dy: translation.height)
                    moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
                    moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
                    box = moved
                case .resizing(let corner, let start):
                    box = resized(start, corner: corner, by: translation, in: bounds)
                }
            }
            .onEnded { _ in
                manipulation = nil
                if let current = box, current.width < Self.minimumSide || current.height < Self.minimumSide {
                    box = nil
                }
            }
    }

    /// What a drag starting here does: grab a corner, move the box, or draw a
    /// new one.
    private func begin(at point: CGPoint) -> Manipulation {
        if let box {
            for corner in Corner.allCases {
                let p = self.point(of: corner, in: box)
                if hypot(p.x - point.x, p.y - point.y) <= Self.handleSize {
                    return .resizing(corner: corner, start: box)
                }
            }
            if box.insetBy(dx: -4, dy: -4).contains(point) { return .moving(start: box) }
        }
        return .drawing(origin: point)
    }

    private func resized(_ start: CGRect, corner: Corner, by delta: CGSize, in bounds: CGRect) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch corner {
        case .topLeading: minX += delta.width; minY += delta.height
        case .topTrailing: maxX += delta.width; minY += delta.height
        case .bottomLeading: minX += delta.width; maxY += delta.height
        case .bottomTrailing: maxX += delta.width; maxY += delta.height
        }
        minX = max(bounds.minX, min(minX, maxX - Self.minimumSide))
        minY = max(bounds.minY, min(minY, maxY - Self.minimumSide))
        maxX = min(bounds.maxX, max(maxX, minX + Self.minimumSide))
        maxY = min(bounds.maxY, max(maxY, minY + Self.minimumSide))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func point(of corner: Corner, in box: CGRect) -> CGPoint {
        switch corner {
        case .topLeading: CGPoint(x: box.minX, y: box.minY)
        case .topTrailing: CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeading: CGPoint(x: box.minX, y: box.maxY)
        case .bottomTrailing: CGPoint(x: box.maxX, y: box.maxY)
        }
    }

    // MARK: - Pieces

    private func dimming(around box: CGRect, in bounds: CGRect) -> some View {
        Path { path in
            path.addRect(bounds)
            path.addRect(box)
        }
        .fill(Color(.sRGB, white: 0, opacity: 0.28), style: FillStyle(eoFill: true))
    }

    private func frame(for box: CGRect) -> some View {
        Rectangle()
            .strokeBorder(colour.swiftUIColor, style: StrokeStyle(lineWidth: 2, dash: manipulation == nil ? [] : [6, 4]))
            .background(colour.swiftUIColor.opacity(0.08))
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
    }

    private var handle: some View {
        Circle()
            .fill(palette.background)
            .overlay(Circle().strokeBorder(colour.swiftUIColor, lineWidth: 2))
            .frame(width: 14, height: 14)
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            barButton("New Card", systemImage: ReaderSelectionMenu.makeCardImage, action: .newCard)
            if targetTitle != nil {
                barButton("Front", systemImage: ReaderSelectionMenu.addToFrontImage, action: .front)
                barButton("Back", systemImage: ReaderSelectionMenu.addToBackImage, action: .back)
            }
            Button {
                box = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear the box")
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
        .opacity(busy ? 0.5 : 1)
        .disabled(busy)
    }

    private func barButton(_ title: String, systemImage: String, action: ReaderAreaAction) -> some View {
        Button {
            guard let box else { return }
            busy = true
            onAction(action, box)
            // The capture reads the page as it is now; the box goes once it
            // has, so the next area can be drawn straight away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.box = nil
                busy = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle(for: action))
    }

    private func accessibilityTitle(for action: ReaderAreaAction) -> String {
        switch action {
        case .newCard: "Make a card from this area"
        case .front: "Add this area to the front of \(targetTitle ?? "the card")"
        case .back: "Add this area to the back of \(targetTitle ?? "the card")"
        }
    }

    /// Under the box when there is room, over it when not, inside the page.
    private func barPosition(for box: CGRect, in bounds: CGRect) -> CGPoint {
        let half: CGFloat = 22
        let gap: CGFloat = 14
        var y = box.maxY + gap + half
        if y + half > bounds.maxY - 8 { y = box.minY - gap - half }
        if y - half < bounds.minY + 8 { y = box.midY }
        let x = min(max(box.midX, bounds.minX + 150), bounds.maxX - 150)
        return CGPoint(x: x, y: y)
    }
}
