import AmgiTheme
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(iOS)

struct TemplateSourceEditor: UIViewRepresentable {
    @Binding var text: String

    let fieldNames: [String]
    let insertableTokens: [String]
    let fieldButtonTitle: String
    let doneButtonTitle: String
    let searchQuery: String
    var fontSize: Double = 14.0
    var fontFamilyRaw: String = "Menlo"

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = resolveFont()
        // UIKit context: no SwiftUI environment access, fall back to system label color.
        textView.textColor = UIColor.label
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.spellCheckingType = .no
        textView.keyboardDismissMode = .interactive
        textView.text = text

        context.coordinator.attach(textView: textView)
        context.coordinator.lastValue = text
        context.coordinator.configureAccessoryView(
            fieldNames: fieldNames,
            insertableTokens: insertableTokens,
            fieldButtonTitle: fieldButtonTitle,
            doneButtonTitle: doneButtonTitle
        )
        context.coordinator.applySearch(searchQuery, in: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // CRITICAL: Update the coordinator's binding reference on every render so it always
        // points to the currently active tab's binding (front/back/css). makeCoordinator()
        // runs only once, so without this the coordinator keeps writing to the original
        // (front) binding regardless of which tab is shown.
        context.coordinator.updateBinding($text)

        // Apply font size / family change. familyName mismatch handles the
        // case where the user switched faces; size mismatch handles +/- steps.
        let desired = resolveFont()
        let current = uiView.font
        if current?.pointSize != desired.pointSize || current?.familyName != desired.familyName {
            uiView.font = desired
        }

        if uiView.text != text, !context.coordinator.isHandlingProgrammaticChange {
            let selectedRange = uiView.selectedRange
            uiView.text = text
            let maxLocation = min(selectedRange.location, uiView.text.utf16.count)
            uiView.selectedRange = NSRange(location: maxLocation, length: 0)
            context.coordinator.lastValue = text
        }

        context.coordinator.attach(textView: uiView)
        context.coordinator.configureAccessoryView(
            fieldNames: fieldNames,
            insertableTokens: insertableTokens,
            fieldButtonTitle: fieldButtonTitle,
            doneButtonTitle: doneButtonTitle
        )
        context.coordinator.applySearch(searchQuery, in: uiView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        weak var textView: UITextView?
        var lastValue: String = ""
        var isHandlingProgrammaticChange = false
        private var lastSearchKey = ""

        private var lastFieldNames: [String] = []
        private var lastInsertableTokens: [String] = []
        private var lastFieldButtonTitle = ""
        private var lastDoneButtonTitle = ""

        init(text: Binding<String>) {
            self._text = text
        }

        func attach(textView: UITextView) {
            self.textView = textView
        }

        /// Called by `updateUIView` on every SwiftUI render to keep the binding
        /// pointing to the currently active tab (front / back / css).
        func updateBinding(_ binding: Binding<String>) {
            _text = binding
        }

        func textViewDidChange(_ textView: UITextView) {
            lastValue = textView.text
            text = textView.text
        }

        func applySearch(_ query: String, in textView: UITextView) {
            let key = "\(query)|\(textView.text ?? "")"
            guard key != lastSearchKey else { return }
            lastSearchKey = key

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let nsText = textView.text as NSString? ?? ""
            let range = nsText.range(of: trimmed, options: [.caseInsensitive])
            guard range.location != NSNotFound else { return }

            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        }

        func configureAccessoryView(
            fieldNames: [String],
            insertableTokens: [String],
            fieldButtonTitle: String,
            doneButtonTitle: String
        ) {
            guard
                fieldNames != lastFieldNames
                    || insertableTokens != lastInsertableTokens
                    || fieldButtonTitle != lastFieldButtonTitle
                    || doneButtonTitle != lastDoneButtonTitle
            else {
                return
            }

            lastFieldNames = fieldNames
            lastInsertableTokens = insertableTokens
            lastFieldButtonTitle = fieldButtonTitle
            lastDoneButtonTitle = doneButtonTitle

            textView?.inputAccessoryView = makeAccessoryView(
                fieldNames: fieldNames,
                insertableTokens: insertableTokens,
                fieldButtonTitle: fieldButtonTitle,
                doneButtonTitle: doneButtonTitle
            )
            textView?.reloadInputViews()
        }
    }
}

private extension TemplateSourceEditor {
    /// Resolves the user's stored font family into a UIFont, falling back to
    /// the monospaced system font when the named face fails to load (e.g.
    /// "Monospace" is a logical name, not an installed face).
    func resolveFont() -> UIFont {
        if let named = UIFont(name: fontFamilyRaw, size: CGFloat(fontSize)) {
            return named
        }
        return .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }
}

private extension TemplateSourceEditor.Coordinator {
    func makeAccessoryView(
        fieldNames: [String],
        insertableTokens: [String],
        fieldButtonTitle: String,
        doneButtonTitle: String
    ) -> UIView {
        // Outer container
        let container = UIView()
        container.backgroundColor = UIColor.secondarySystemBackground
        container.frame = CGRect(x: 0, y: 0, width: 0, height: 46)

        let topLine = UIView()
        topLine.backgroundColor = UIColor.separator
        topLine.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topLine)

        // Scrollable left area
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        container.addSubview(scrollView)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        scrollView.addSubview(stack)

        stack.addArrangedSubview(makeIconButton(systemName: "arrow.uturn.backward") { [weak self] in
            self?.textView?.undoManager?.undo()
        })
        stack.addArrangedSubview(makeIconButton(systemName: "arrow.uturn.forward") { [weak self] in
            self?.textView?.undoManager?.redo()
        })

        if !fieldNames.isEmpty {
            stack.addArrangedSubview(makeSeparatorView())
            let fieldActions = fieldNames.map { name in
                UIAction(title: name) { [weak self] _ in self?.insert("{{\(name)}}") }
            }
            stack.addArrangedSubview(makeMenuButton(
                title: fieldButtonTitle,
                menu: UIMenu(children: fieldActions)
            ))
        }

        if !insertableTokens.isEmpty {
            stack.addArrangedSubview(makeSeparatorView())
            let tokenActions = insertableTokens.map { token in
                UIAction(title: token) { [weak self] _ in self?.insert(token) }
            }
            stack.addArrangedSubview(makeMenuButton(
                title: "Insert",
                menu: UIMenu(children: tokenActions)
            ))
        }

        // Done button pinned to right, outside scroll area
        let doneButton = makeDoneButton(title: doneButtonTitle) { [weak self] in
            self?.textView?.resignFirstResponder()
        }
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(doneButton)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: container.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 0.5),

            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            doneButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        return container
    }

    func insert(_ string: String) {
        guard let textView, let range = textView.selectedTextRange else { return }
        isHandlingProgrammaticChange = true
        textView.replace(range, withText: string)
        isHandlingProgrammaticChange = false
        textViewDidChange(textView)
    }

    func makeIconButton(systemName: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: systemName)
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        button.configuration = cfg
        button.tintColor = UIColor.label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    func makeMenuButton(title: String, menu: UIMenu) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.plain()
        cfg.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .regular)])
        )
        cfg.image = UIImage(systemName: "chevron.down")
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 3
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 6)
        button.configuration = cfg
        button.tintColor = UIColor.label
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func makeDoneButton(title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.plain()
        cfg.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)])
        )
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 4)
        button.configuration = cfg
        button.tintColor = UIColor.tintColor
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    func makeSeparatorView() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.separator
        view.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        view.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return view
    }
}

#else

/// macOS variant: a SwiftUI View wrapping an NSTextView host plus the
/// accessory toolbar rendered as a native button/menu row (macOS has no
/// `inputAccessoryView`). Editing semantics mirror the iOS implementation.
struct TemplateSourceEditor: View {
    @Binding var text: String

    let fieldNames: [String]
    let insertableTokens: [String]
    let fieldButtonTitle: String
    let doneButtonTitle: String
    let searchQuery: String
    var fontSize: Double = 14.0
    var fontFamilyRaw: String = "Menlo"

    @State private var bridge = TemplateEditorBridge()

    var body: some View {
        VStack(spacing: 0) {
            MacTemplateSourceHost(
                text: $text,
                searchQuery: searchQuery,
                font: resolveFont(),
                bridge: bridge
            )
            Divider()
            toolbar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                bridge.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Undo")

            Button {
                bridge.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Redo")

            if !fieldNames.isEmpty {
                Divider().frame(height: 20)
                Menu(fieldButtonTitle) {
                    ForEach(fieldNames, id: \.self) { name in
                        Button(name) { bridge.insert("{{\(name)}}") }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !insertableTokens.isEmpty {
                Divider().frame(height: 20)
                Menu("Insert") {
                    ForEach(insertableTokens, id: \.self) { token in
                        Button(token) { bridge.insert(token) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            Button(doneButtonTitle) {
                bridge.resignFirstResponder()
            }
            .buttonStyle(.borderless)
        }
    }

    /// Resolves the user's stored font family into an NSFont, falling back
    /// to the monospaced system font when the named face fails to load.
    private func resolveFont() -> NSFont {
        if let named = NSFont(name: fontFamilyRaw, size: CGFloat(fontSize)) {
            return named
        }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }
}

/// Bridges the SwiftUI toolbar to the live NSTextView held by the host.
@MainActor
private final class TemplateEditorBridge {
    weak var textView: NSTextView?

    func insert(_ string: String) {
        guard let textView else { return }
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    func undo() {
        textView?.undoManager?.undo()
    }

    func redo() {
        textView?.undoManager?.redo()
    }

    func resignFirstResponder() {
        textView?.window?.makeFirstResponder(nil)
    }
}

private struct MacTemplateSourceHost: NSViewRepresentable {
    @Binding var text: String
    let searchQuery: String
    let font: NSFont
    let bridge: TemplateEditorBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text

        context.coordinator.attach(textView: textView)
        bridge.textView = textView
        context.coordinator.lastValue = text
        context.coordinator.applySearch(searchQuery, in: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Mirror the iOS update path: refresh the binding reference on every
        // render so tab switches (front / back / css) write to the right one.
        context.coordinator.updateBinding($text)
        bridge.textView = textView

        if textView.font != font {
            textView.font = font
        }

        if textView.string != text, !context.coordinator.isHandlingProgrammaticChange {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let maxLocation = min(selectedRange.location, text.utf16.count)
            textView.setSelectedRange(NSRange(location: maxLocation, length: 0))
            context.coordinator.lastValue = text
        }

        context.coordinator.applySearch(searchQuery, in: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        weak var textView: NSTextView?
        var lastValue: String = ""
        var isHandlingProgrammaticChange = false
        private var lastSearchKey = ""

        init(text: Binding<String>) {
            self._text = text
        }

        func attach(textView: NSTextView) {
            self.textView = textView
        }

        func updateBinding(_ binding: Binding<String>) {
            _text = binding
        }

        func textDidChange(_ notification: Notification) {
            lastValue = textView?.string ?? ""
            text = lastValue
        }

        func applySearch(_ query: String, in textView: NSTextView) {
            let key = "\(query)|\(textView.string)"
            guard key != lastSearchKey else { return }
            lastSearchKey = key

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let nsText = textView.string as NSString
            let range = nsText.range(of: trimmed, options: [.caseInsensitive])
            guard range.location != NSNotFound else { return }

            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }
}

#endif
