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
    var chrome: NoteFieldChromeState = .init()
    var paletteOverride: Palette? = nil
    var perform: (NoteFieldFormatAction) -> Void
    /// HTML-source auto-close state (session-backed by the host chrome).
    var autoCloseEnabled = true
    var onToggleAutoClose: (() -> Void)?

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
                    icon("arrow.uturn.backward", .undo, enabled: chrome.canUndo, label: "Undo")
                    icon("arrow.uturn.forward", .redo, enabled: chrome.canRedo, label: "Redo")
                }
                separator
                group {
                    icon("bold", .bold, selected: chrome.style.bold, label: "Bold")
                    icon("italic", .italic, selected: chrome.style.italic, label: "Italic")
                    icon("underline", .underline, selected: chrome.style.underline, label: "Underline")
                    icon("strikethrough", .strike, selected: chrome.style.strike, label: "Strikethrough")
                    Menu {
                        Button("Superscript") { perform(.superscript) }
                        Button("Subscript") { perform(.subscript) }
                        Button("Code") { perform(.code) }
                        Menu("Math") {
                            Button("Inline \\(\\)") { perform(.math) }
                            Button("Block \\[\\]") { perform(.mathBlock) }
                            Button("LaTeX chemistry \\ce") { perform(.mathLatex(environment: "ce")) }
                            Button("LaTeX equation") { perform(.mathLatex(environment: "equation")) }
                        }
                        Menu("Text color") {
                            colorButtons(isHighlight: false)
                        }
                        Menu("Highlight") {
                            colorButtons(isHighlight: true)
                        }
                        Button("Clear Formatting") { perform(.clear) }
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(
                                chrome.style.superscript || chrome.style.subscript || chrome.style.code
                                    ? palette.accent
                                    : palette.textPrimary
                            )
                            .frame(width: NoteFieldToolbarMetrics.buttonWidth, height: NoteFieldToolbarMetrics.buttonHeight)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Format")
                }
                separator
                group {
                    icon(
                        "text.alignleft",
                        .align(.left),
                        selected: chrome.alignment == .left,
                        label: "Align left"
                    )
                    icon(
                        "text.aligncenter",
                        .align(.center),
                        selected: chrome.alignment == .center,
                        label: "Align center"
                    )
                    icon(
                        "text.alignright",
                        .align(.right),
                        selected: chrome.alignment == .right,
                        label: "Align right"
                    )
                }
                separator
                group {
                    Menu {
                        Button("Disc") { perform(.list(.bullet)) }
                        Button("Circle") { perform(.list(.circle)) }
                        Button("Square") { perform(.list(.square)) }
                    } label: {
                        menuGlyph(
                            "list.bullet",
                            selected: chrome.listKind.isBullet,
                            label: "Bulleted list"
                        )
                    }
                    Menu {
                        Button("1, 2, 3") { perform(.list(.numbered)) }
                        Button("a, b, c") { perform(.list(.lowerAlpha)) }
                        Button("A, B, C") { perform(.list(.upperAlpha)) }
                        Button("i, ii, iii") { perform(.list(.lowerRoman)) }
                        Button("I, II, III") { perform(.list(.upperRoman)) }
                    } label: {
                        menuGlyph(
                            "list.number",
                            selected: chrome.listKind.isNumbered,
                            label: "Numbered list"
                        )
                    }
                    icon("increase.indent", .indent, enabled: !chrome.isHTMLSource, label: "Increase indent")
                    icon("decrease.indent", .outdent, enabled: chrome.indent > 0 && !chrome.isHTMLSource, label: "Decrease indent")
                }
                if chrome.showsCloze {
                    separator
                    group {
                        icon("rectangle.dashed", .cloze, label: "Cloze")
                        icon("plus.rectangle.on.rectangle", .clozeSame, label: "Cloze same number")
                    }
                }
                separator
                group {
                    icon(
                        "chevron.left.forwardslash.chevron.right",
                        .toggleHTMLSource,
                        selected: chrome.isHTMLSource,
                        label: "HTML source"
                    )
                    icon("camera", .camera, label: "Take photo")
                    icon("photo", .photoLibrary, label: "Choose from library")
                    icon("paperclip", .attach, label: "Attach file")
                    icon("mic", .recordAudio, label: "Record audio")
                    if chrome.isHTMLSource {
                        separator
                        group {
                            autoCloseToggle
                        }
                        if let line = chrome.sourceCursorLine, let col = chrome.sourceCursorColumn {
                            Text("Ln \(line), Col \(col)")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(palette.textSecondary)
                                .monospacedDigit()
                                .accessibilityLabel("Cursor line \(line), column \(col)")
                        }
                    }
                    Menu {
                        Button("Small (320px)") { perform(.imageSize("320")) }
                        Button("Medium (640px)") { perform(.imageSize("640")) }
                        Button("Large (960px)") { perform(.imageSize("960")) }
                        Divider()
                        Button("Restore original size") { perform(.imageSize(nil)) }
                    } label: {
                        menuGlyph(
                            "photo.artframe",
                            selected: chrome.selectedImage != nil,
                            label: imageSizeLabel
                        )
                    }
                    .disabled(chrome.selectedImage == nil || chrome.isHTMLSource)
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

    private func menuGlyph(_ systemName: String, selected: Bool, label: String) -> some View {
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
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var autoCloseToggle: some View {
        Button {
            onToggleAutoClose?()
        } label: {
            Image(systemName: autoCloseEnabled ? "chevron.left.forwardslash.chevron.right.circle.fill" : "chevron.left.forwardslash.chevron.right.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(autoCloseEnabled ? palette.accent : palette.textPrimary)
                .frame(width: NoteFieldToolbarMetrics.buttonWidth, height: NoteFieldToolbarMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Automatic closing tags (\(autoCloseEnabled ? "on" : "off"))")
        .accessibilityLabel("Automatic closing tags, currently \(autoCloseEnabled ? "on" : "off")")
        .accessibilityAddTraits(autoCloseEnabled ? .isSelected : [])
    }

    private var imageSizeLabel: String {
        if let image = chrome.selectedImage {
            if let width = image.widthAttr {
                return "Image width \(width)px — tap to resize"
            }
            return "Original image size — tap to resize"
        }
        return "Image size (tap an image first)"
    }

    /// Desktop-style text/highlight palette. "Default" clears back to the
    /// label color (nil hex) so clearing never leaves a stale span behind.
    @ViewBuilder
    private func colorButtons(isHighlight: Bool) -> some View {
        let colors: [(String, String)] = [
            ("Default", ""),
            ("Red", "#ff0000"),
            ("Orange", "#ffa500"),
            ("Yellow", "#ffff00"),
            ("Green", "#008000"),
            ("Blue", "#0000ff"),
            ("Purple", "#800080"),
            ("Gray", "#808080"),
            ("Black", "#000000"),
        ]
        ForEach(colors, id: \.0) { name, hex in
            Button(name) {
                if isHighlight {
                    perform(.highlight(hex.isEmpty ? nil : hex))
                } else {
                    perform(.textColor(hex.isEmpty ? nil : hex))
                }
            }
        }
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
        .disabled(!enabled && (action == .undo || action == .redo || action == .indent || action == .outdent))
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

    func update(chrome: NoteFieldChromeState, palette: Palette) {
        bar.chrome = chrome
        bar.paletteOverride = palette
        hosting.rootView = bar
    }
}

#endif
