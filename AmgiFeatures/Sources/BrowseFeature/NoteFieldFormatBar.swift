import SwiftUI
import AmgiTheme
#if canImport(UIKit)
import UIKit
#endif

enum NoteFieldToolbarMetrics {
    /// Taller than the capsule so the glass reads as floating (FUTO Notes).
    static let barHeight: CGFloat = 56
    static let capsuleHeight: CGFloat = 40
    static let capsuleGap: CGFloat = 8
    static let buttonHeight: CGFloat = 36
    static let buttonWidth: CGFloat = 44
    static let contentPad: CGFloat = 10
    static let separatorHeight: CGFloat = 20
}

struct NoteFieldFormatBar: View {
    var showsDismiss: Bool = true
    var style: NoteFieldHTML.Style = .init()
    var canUndo: Bool = false
    var canRedo: Bool = false
    var listKind: NoteFieldHTML.ListKind = .none
    var showsCloze: Bool = false
    var paletteOverride: Palette? = nil
    var perform: (NoteFieldFormatAction) -> Void

    @Environment(\.palette) private var environmentPalette
    private var palette: Palette { paletteOverride ?? environmentPalette }

    var body: some View {
        HStack(spacing: NoteFieldToolbarMetrics.capsuleGap) {
            scrollingItems
                .frame(height: NoteFieldToolbarMetrics.capsuleHeight)
                .clipShape(.capsule)
                .amgiMaterial(.regular, in: Capsule(), interactive: true)
            if showsDismiss {
                Button {
                    perform(.dismiss)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .frame(
                            width: NoteFieldToolbarMetrics.capsuleHeight,
                            height: NoteFieldToolbarMetrics.capsuleHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide keyboard")
                .clipShape(.capsule)
                .amgiMaterial(.regular, in: Capsule(), interactive: true)
            }
        }
        .padding(.horizontal, NoteFieldToolbarMetrics.capsuleGap)
        .frame(height: NoteFieldToolbarMetrics.barHeight)
    }

    private var scrollingItems: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                group {
                    icon("arrow.uturn.backward", .undo, enabled: canUndo, label: "Undo")
                    icon("arrow.uturn.forward", .redo, enabled: canRedo, label: "Redo")
                }
                separator
                group {
                    icon("bold", .bold, selected: style.bold, label: "Bold")
                    icon("italic", .italic, selected: style.italic, label: "Italic")
                    icon("underline", .underline, selected: style.underline, label: "Underline")
                    icon("strikethrough", .strike, selected: style.strike, label: "Strikethrough")
                    Menu {
                        Button("Superscript") { perform(.superscript) }
                        Button("Subscript") { perform(.subscript) }
                        Button("Code") { perform(.code) }
                        Button("MathJax") { perform(.math) }
                        Button("Clear Formatting") { perform(.clear) }
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(style.superscript || style.subscript || style.code ? palette.accent : palette.textPrimary)
                            .frame(width: NoteFieldToolbarMetrics.buttonWidth, height: NoteFieldToolbarMetrics.buttonHeight)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Format")
                }
                separator
                group {
                    icon("list.bullet", .bulletList, selected: listKind == .bullet, label: "Bulleted list")
                    icon("list.number", .numberedList, selected: listKind == .numbered, label: "Numbered list")
                }
                if showsCloze {
                    separator
                    group {
                        icon("rectangle.dashed", .cloze, label: "Cloze")
                        icon("plus.rectangle.on.rectangle", .clozeSame, label: "Cloze same number")
                    }
                }
                separator
                group {
                    icon("camera", .camera, label: "Take photo")
                    icon("photo", .photoLibrary, label: "Choose from library")
                    icon("paperclip", .attach, label: "Attach file")
                }
            }
            .padding(.horizontal, NoteFieldToolbarMetrics.contentPad)
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2, content: content)
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: 1, height: NoteFieldToolbarMetrics.separatorHeight)
            .padding(.horizontal, 4)
    }

    private func icon(
        _ systemName: String,
        _ action: NoteFieldFormatAction,
        enabled: Bool = true,
        selected: Bool = false,
        label: String
    ) -> some View {
        Button {
            perform(action)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? palette.accent : palette.textPrimary)
                .frame(width: NoteFieldToolbarMetrics.buttonWidth, height: NoteFieldToolbarMetrics.buttonHeight)
                .background {
                    if selected {
                        Capsule().fill(palette.accent.opacity(0.16))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && (action == .undo || action == .redo))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(iOS)

/// Keyboard accessory using `UIInputView`'s system keyboard backdrop, matching
/// FUTO Notes: floating glass capsules, no opaque plank, no home-indicator gap.
final class NoteFieldFormatAccessory: UIInputView {
    private let hosting: UIHostingController<NoteFieldFormatBar>
    private var bar: NoteFieldFormatBar

    init(perform: @escaping (NoteFieldFormatAction) -> Void) {
        bar = NoteFieldFormatBar(perform: perform)
        hosting = UIHostingController(rootView: bar)
        hosting.safeAreaRegions = []
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: NoteFieldToolbarMetrics.barHeight),
            inputViewStyle: .keyboard
        )
        autoresizingMask = [.flexibleWidth]
        allowsSelfSizing = true
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: NoteFieldToolbarMetrics.barHeight)
    }

    func update(
        style: NoteFieldHTML.Style,
        canUndo: Bool,
        canRedo: Bool,
        listKind: NoteFieldHTML.ListKind,
        showsCloze: Bool,
        palette: Palette
    ) {
        bar.style = style
        bar.canUndo = canUndo
        bar.canRedo = canRedo
        bar.listKind = listKind
        bar.showsCloze = showsCloze
        bar.paletteOverride = palette
        hosting.rootView = bar
    }
}

#endif
