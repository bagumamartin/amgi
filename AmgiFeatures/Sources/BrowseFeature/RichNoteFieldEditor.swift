import SwiftUI
import AmgiTheme
import AmgiUI
import AnkiClients
import Dependencies
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Note field editor: WYSIWYG attributed text over Anki HTML fragments.
/// Format actions go through `NoteFieldEditingSession` so the keyboard
/// accessory, hardware-keyboard nav bar, and Mac strip share one responder.
struct RichNoteFieldEditor: View {
    @Binding var htmlText: String
    var preservesSourceHTML = false
    var fieldIndex: Int = 0
    var focusGeneration: Int = 0

    @Environment(\.noteFieldEditingSession) private var session
    @Environment(\.palette) private var palette
    @State private var localSession = NoteFieldEditingSession()

    private var resolvedSession: NoteFieldEditingSession {
        session ?? localSession
    }

    var body: some View {
        #if os(iOS)
        NoteFieldUIKitHost(
            htmlText: $htmlText,
            preservesSourceHTML: preservesSourceHTML,
            fieldIndex: fieldIndex,
            focusGeneration: focusGeneration,
            session: resolvedSession,
            palette: palette
        )
        #else
        NoteFieldAppKitHost(
            htmlText: $htmlText,
            preservesSourceHTML: preservesSourceHTML,
            fieldIndex: fieldIndex,
            focusGeneration: focusGeneration,
            session: resolvedSession,
            palette: palette
        )
        #endif
    }
}

#if os(iOS)

private struct NoteFieldUIKitHost: UIViewRepresentable {
    @Binding var htmlText: String
    var preservesSourceHTML: Bool
    var fieldIndex: Int
    var focusGeneration: Int
    var session: NoteFieldEditingSession
    var palette: Palette

    @Dependency(\.mediaClient) private var mediaClient

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(htmlText: $htmlText, session: session, fieldIndex: fieldIndex, palette: palette)
        coordinator.resolveImageURL = { [mediaClient] name in mediaClient.localURL(name) }
        return coordinator
    }

    func makeUIView(context: Context) -> NoteFieldTextView {
        let textView = NoteFieldTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.font = NoteFieldHTML.defaultFont()
        textView.textColor = .label
        textView.adjustsFontForContentSizeCategory = true
        textView.allowsEditingTextAttributes = true
        context.coordinator.attach(textView: textView)
        context.coordinator.load(htmlText, preservesSourceHTML: preservesSourceHTML)

        let accessory = NoteFieldFormatAccessory { [weak coordinator = context.coordinator] action in
            coordinator?.session.perform(action)
        }
        textView.formatAccessory = accessory
        context.coordinator.accessory = accessory
        textView.accessoryEnabled = !session.hasHardwareKeyboard
        context.coordinator.installAssistantItems()
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NoteFieldTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(max(NoteFieldLayout.minHeight, fitting.height), NoteFieldLayout.maxHeight)
        uiView.isScrollEnabled = fitting.height > NoteFieldLayout.maxHeight
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ uiView: NoteFieldTextView, context: Context) {
        context.coordinator.fieldIndex = fieldIndex
        context.coordinator.session = session
        context.coordinator.palette = palette
        context.coordinator.resolveImageURL = { mediaClient.localURL($0) }
        uiView.accessoryEnabled = !session.hasHardwareKeyboard
        context.coordinator.refreshAccessory()

        let source = session.htmlSourceFields.contains(fieldIndex)
        if source != context.coordinator.isShowingHTMLSource {
            context.coordinator.commit()
            context.coordinator.isShowingHTMLSource = source
            context.coordinator.load(htmlText, preservesSourceHTML: source)
            return
        }

        if context.coordinator.lastAppliedFocusGeneration != focusGeneration {
            context.coordinator.lastAppliedFocusGeneration = focusGeneration
            if fieldIndex == 0, focusGeneration > 0 {
                DispatchQueue.main.async { uiView.becomeFirstResponder() }
            }
        }

        guard htmlText != context.coordinator.lastHTML else { return }
        context.coordinator.load(htmlText, preservesSourceHTML: context.coordinator.isShowingHTMLSource)
    }

    final class Coordinator: NSObject, UITextViewDelegate, NoteFieldFormatResponder {
        @Binding var htmlText: String
        var session: NoteFieldEditingSession
        var fieldIndex: Int
        var palette: Palette
        weak var textView: NoteFieldTextView?
        weak var accessory: NoteFieldFormatAccessory?
        var lastHTML: String = ""
        var isEditing = false
        var lastAppliedFocusGeneration = 0
        var isShowingHTMLSource = false
        var resolveImageURL: (String) -> URL? = { _ in nil }
        private let baseFont = NoteFieldHTML.defaultFont()

        init(
            htmlText: Binding<String>,
            session: NoteFieldEditingSession,
            fieldIndex: Int,
            palette: Palette
        ) {
            self._htmlText = htmlText
            self.session = session
            self.fieldIndex = fieldIndex
            self.palette = palette
        }

        func attach(textView: NoteFieldTextView) {
            self.textView = textView
        }

        func load(_ html: String, preservesSourceHTML: Bool) {
            guard let textView else { return }
            let attributed: NSAttributedString
            if preservesSourceHTML {
                attributed = NSAttributedString(
                    string: html,
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
                        .foregroundColor: UIColor.label,
                    ]
                )
            } else {
                attributed = NoteFieldHTML.attributedString(from: html, font: baseFont)
            }
            textView.textStorage.setAttributedString(attributed)
            lastHTML = html
            if !preservesSourceHTML {
                hydrateImages()
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            session.attach(responder: self, fieldIndex: fieldIndex)
            session.refreshChrome()
            refreshAccessory()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            session.detach(responder: self)
            commit()
        }

        func textViewDidChange(_ textView: UITextView) {
            commit()
            session.refreshChrome()
            refreshAccessory()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            session.refreshChrome()
            refreshAccessory()
        }

        var canUndo: Bool { textView?.undoManager?.canUndo ?? false }
        var canRedo: Bool { textView?.undoManager?.canRedo ?? false }
        var currentStyle: NoteFieldHTML.Style {
            guard let textView else { return .init() }
            return NoteFieldHTML.style(from: textView.typingAttributes)
        }

        var currentListKind: NoteFieldHTML.ListKind {
            guard let textView else { return .none }
            let location = max(0, min(textView.selectedRange.location, max(0, textView.attributedText.length - 1)))
            return NoteFieldHTML.listKind(in: textView.attributedText, at: location)
        }

        var currentAlignment: NoteFieldHTML.Alignment {
            guard let textView else { return .unspecified }
            if textView.attributedText.length == 0 {
                return NoteFieldHTML.blockStyle(from: textView.typingAttributes).alignment
            }
            let location = max(0, min(textView.selectedRange.location, max(0, textView.attributedText.length - 1)))
            return NoteFieldHTML.blockStyle(in: textView.attributedText, at: location).alignment
        }

        var currentIndent: Int {
            guard let textView else { return 0 }
            if textView.attributedText.length == 0 {
                return NoteFieldHTML.blockStyle(from: textView.typingAttributes).indent
            }
            let location = max(0, min(textView.selectedRange.location, max(0, textView.attributedText.length - 1)))
            return NoteFieldHTML.blockStyle(in: textView.attributedText, at: location).indent
        }

        var isHTMLSource: Bool {
            session.htmlSourceFields.contains(fieldIndex)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !isHTMLSource, text == "\n" else { return true }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            guard let selected = NoteFieldHTML.handleReturn(on: attributed, range: range, font: baseFont) else {
                return true
            }
            textView.attributedText = attributed
            textView.selectedRange = selected
            commit()
            session.refreshChrome()
            refreshAccessory()
            return false
        }

        func perform(_ action: NoteFieldFormatAction) {
            guard let textView else { return }
            if isHTMLSource {
                switch action {
                case .undo, .redo, .toggleHTMLSource, .dismiss, .camera, .photoLibrary, .attach: break
                default: return
                }
            }
            switch action {
            case .undo: textView.undoManager?.undo()
            case .redo: textView.undoManager?.redo()
            case .bold: toggle(\.bold)
            case .italic: toggle(\.italic)
            case .underline: toggle(\.underline)
            case .strike: toggle(\.strike)
            case .superscript: toggle(\.superscript)
            case .subscript: toggle(\.subscript)
            case .code: toggle(\.code)
            case .math: wrapPlain(#"\("#, suffix: #"\)"#)
            case .clear: clearFormatting()
            case .list(let kind): toggleList(kind)
            case .align(let alignment): applyAlignment(alignment)
            case .indent: changeIndent(1)
            case .outdent: changeIndent(-1)
            case .toggleHTMLSource:
                commit()
                if session.htmlSourceFields.contains(fieldIndex) {
                    session.htmlSourceFields.remove(fieldIndex)
                } else {
                    session.htmlSourceFields.insert(fieldIndex)
                }
                isShowingHTMLSource = isHTMLSource
                load(htmlText, preservesSourceHTML: isHTMLSource)
            case .cloze: wrapCloze(increment: true)
            case .clozeSame: wrapCloze(increment: false)
            case .camera:
                session.perform(.camera)
            case .photoLibrary:
                session.perform(.photoLibrary)
            case .attach:
                session.perform(.attach)
            case .dismiss: textView.resignFirstResponder()
            }
            switch action {
            case .toggleHTMLSource, .camera, .photoLibrary, .attach: break
            default: commit()
            }
            session.refreshChrome()
            refreshAccessory()
        }

        func insertImage(filename: String) {
            guard let textView else { return }
            let placeholder = NoteFieldHTML.imagePlaceholder(
                filename: filename,
                font: baseFont,
                style: currentStyle,
                listKind: currentListKind
            )
            textView.textStorage.replaceCharacters(in: textView.selectedRange, with: placeholder)
            let cursor = textView.selectedRange.location + placeholder.length
            textView.selectedRange = NSRange(location: cursor, length: 0)
            commit()
            session.refreshChrome()
            hydrateImages()
        }

        func hydrateImages() {
            guard !isShowingHTMLSource, let textView else { return }
            let storage = textView.textStorage
            var filenames: [String] = []
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                guard let attachment = value as? NoteFieldImageAttachment else { return }
                filenames.append(attachment.filename)
            }
            for filename in filenames {
                guard let url = resolveImageURL(filename) else { continue }
                if let cached = DownsampledImageLoader.cached(url: url, maxPixelSize: 1400) {
                    applyLoadedImage(cached, filename: filename)
                    continue
                }
                Task { [weak self] in
                    let image = await DownsampledImageLoader.load(url: url, maxPixelSize: 1400)
                    await MainActor.run {
                        self?.applyLoadedImage(image, filename: filename)
                    }
                }
            }
        }

        func applyLoadedImage(_ image: UIImage?, filename: String) {
            guard let image, let textView else { return }
            let framed = NoteFieldHTML.framedImage(image)
            let storage = textView.textStorage
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                guard let attachment = value as? NoteFieldImageAttachment,
                      attachment.filename == filename else { return }
                attachment.image = framed
                textView.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                textView.layoutManager.invalidateDisplay(forCharacterRange: range)
            }
            textView.invalidateIntrinsicContentSize()
        }

        func insertSound(filename: String) {
            wrapPlain("[sound:\(filename)]", suffix: "")
            commit()
            session.refreshChrome()
        }

        func installAssistantItems() {
            guard let textView else { return }
            func item(_ name: String, _ action: NoteFieldFormatAction, label: String) -> UIBarButtonItem {
                UIBarButtonItem(
                    image: UIImage(systemName: name),
                    primaryAction: UIAction { [weak self] _ in self?.perform(action) }
                ).applying { $0.accessibilityLabel = label }
            }
            textView.inputAssistantItem.leadingBarButtonGroups = [
                UIBarButtonItemGroup(
                    barButtonItems: [
                        item("bold", .bold, label: "Bold"),
                        item("italic", .italic, label: "Italic"),
                        item("underline", .underline, label: "Underline"),
                    ],
                    representativeItem: nil
                )
            ]
            textView.inputAssistantItem.trailingBarButtonGroups = [
                UIBarButtonItemGroup(
                    barButtonItems: [
                        item("strikethrough", .strike, label: "Strikethrough"),
                        item("textformat", .clear, label: "Clear formatting"),
                    ],
                    representativeItem: nil
                )
            ]
        }

        fileprivate func refreshAccessory() {
            accessory?.update(chrome: session.chrome, palette: palette)
            textView?.accessoryEnabled = !session.hasHardwareKeyboard
        }

        fileprivate func commit() {
            guard let textView else { return }
            let encoded = isHTMLSource ? (textView.text ?? "") : NoteFieldHTML.encode(textView.attributedText)
            lastHTML = encoded
            htmlText = encoded
        }

        private func toggleList(_ kind: NoteFieldHTML.ListKind) {
            guard let textView else { return }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            let selected = NoteFieldHTML.toggleListKind(
                on: attributed,
                range: textView.selectedRange,
                kind: kind,
                font: baseFont
            )
            textView.attributedText = attributed
            textView.selectedRange = selected
            let block = NoteFieldHTML.blockStyle(in: attributed, at: min(selected.location, max(0, attributed.length - 1)))
            textView.typingAttributes = NoteFieldHTML.attributes(for: currentStyle, font: baseFont, block: block)
        }

        private func applyAlignment(_ alignment: NoteFieldHTML.Alignment) {
            guard let textView else { return }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            let selected = textView.selectedRange
            NoteFieldHTML.applyAlignment(on: attributed, range: selected, alignment: alignment, font: baseFont)
            textView.attributedText = attributed
            textView.selectedRange = selected
            let block = NoteFieldHTML.blockStyle(in: attributed, at: min(selected.location, max(0, attributed.length - 1)))
            textView.typingAttributes = NoteFieldHTML.attributes(for: currentStyle, font: baseFont, block: block)
        }

        private func changeIndent(_ delta: Int) {
            guard let textView else { return }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            let selected = textView.selectedRange
            NoteFieldHTML.changeIndent(on: attributed, range: selected, delta: delta, font: baseFont)
            textView.attributedText = attributed
            textView.selectedRange = selected
        }

        private func wrapCloze(increment: Bool) {
            guard let textView else { return }
            let ordinal = session.nextClozeOrdinal(increment: increment)
            wrapPlain("{{c\(ordinal)::", suffix: "}}")
        }

        private func wrapPlain(_ prefix: String, suffix: String) {
            guard let textView else { return }
            let selected = textView.selectedRange
            let attrs = NoteFieldHTML.attributes(for: currentStyle, font: baseFont, listKind: currentListKind)
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            attributed.insert(NSAttributedString(string: suffix, attributes: attrs), at: selected.location + selected.length)
            attributed.insert(NSAttributedString(string: prefix, attributes: attrs), at: selected.location)
            textView.attributedText = attributed
            textView.selectedRange = NSRange(
                location: selected.location + (prefix as NSString).length,
                length: selected.length
            )
        }

        private func toggle(_ keyPath: WritableKeyPath<NoteFieldHTML.Style, Bool>) {
            guard let textView else { return }
            let range = textView.selectedRange
            if range.length == 0 {
                var style = NoteFieldHTML.style(from: textView.typingAttributes)
                style[keyPath: keyPath].toggle()
                textView.typingAttributes = NoteFieldHTML.attributes(for: style, font: baseFont)
                return
            }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            let currentlyOn = traitIsUniformlyOn(attributed, range: range, keyPath: keyPath)
            attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                var style = NoteFieldHTML.style(from: attributes)
                style[keyPath: keyPath] = !currentlyOn
                attributed.addAttributes(
                    NoteFieldHTML.attributes(for: style, font: baseFont),
                    range: subrange
                )
            }
            textView.attributedText = attributed
            textView.selectedRange = range
        }

        private func clearFormatting() {
            guard let textView else { return }
            let range = textView.selectedRange
            let target = range.length > 0 ? range : NSRange(location: 0, length: textView.attributedText.length)
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            attributed.setAttributes(
                NoteFieldHTML.attributes(for: .init(), font: baseFont),
                range: target
            )
            textView.attributedText = attributed
            textView.selectedRange = range.length > 0 ? range : NSRange(location: target.length, length: 0)
        }

        private func traitIsUniformlyOn(
            _ attributed: NSAttributedString,
            range: NSRange,
            keyPath: KeyPath<NoteFieldHTML.Style, Bool>
        ) -> Bool {
            var allOn = true
            attributed.enumerateAttributes(in: range, options: []) { attributes, _, stop in
                if !NoteFieldHTML.style(from: attributes)[keyPath: keyPath] {
                    allOn = false
                    stop.pointee = true
                }
            }
            return allOn
        }
    }
}

/// `inputAccessoryView` is overridable so a hardware keyboard can hide the
/// stranded bottom bar without tearing down the hosted SwiftUI accessory.
final class NoteFieldTextView: UITextView {
    var formatAccessory: UIView?
    var accessoryEnabled = true {
        didSet {
            if oldValue != accessoryEnabled {
                reloadInputViews()
            }
        }
    }

    override var inputAccessoryView: UIView? {
        get { accessoryEnabled ? formatAccessory : nil }
        set { formatAccessory = newValue }
    }
}

private extension UIBarButtonItem {
    func applying(_ body: (UIBarButtonItem) -> Void) -> UIBarButtonItem {
        body(self)
        return self
    }
}

#else

private struct NoteFieldAppKitHost: NSViewRepresentable {
    @Binding var htmlText: String
    var preservesSourceHTML: Bool
    var fieldIndex: Int
    var focusGeneration: Int
    var session: NoteFieldEditingSession
    var palette: Palette

    @Dependency(\.mediaClient) private var mediaClient

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(htmlText: $htmlText, session: session, fieldIndex: fieldIndex)
        coordinator.resolveImageURL = { [mediaClient] name in mediaClient.localURL(name) }
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NoteFieldHTML.defaultFont()
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        context.coordinator.attach(textView: textView)
        context.coordinator.load(htmlText, preservesSourceHTML: preservesSourceHTML)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let textView = nsView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let fitting = used.height + textView.textContainerInset.height * 2
        let height = min(max(NoteFieldLayout.minHeight, fitting), NoteFieldLayout.maxHeight)
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.fieldIndex = fieldIndex
        context.coordinator.session = session
        _ = palette
        context.coordinator.attach(textView: textView)

        let source = session.htmlSourceFields.contains(fieldIndex)
        if source != context.coordinator.isShowingHTMLSource {
            context.coordinator.commit()
            context.coordinator.isShowingHTMLSource = source
            context.coordinator.load(htmlText, preservesSourceHTML: source)
            return
        }

        if context.coordinator.lastAppliedFocusGeneration != focusGeneration {
            context.coordinator.lastAppliedFocusGeneration = focusGeneration
            if fieldIndex == 0, focusGeneration > 0 {
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            }
        }

        context.coordinator.resolveImageURL = { mediaClient.localURL($0) }
        guard htmlText != context.coordinator.lastHTML else { return }
        context.coordinator.load(htmlText, preservesSourceHTML: context.coordinator.isShowingHTMLSource)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NoteFieldFormatResponder {
        @Binding var htmlText: String
        var session: NoteFieldEditingSession
        var fieldIndex: Int
        weak var textView: NSTextView?
        var lastHTML: String = ""
        var isEditing = false
        var lastAppliedFocusGeneration = 0
        var isShowingHTMLSource = false
        var resolveImageURL: (String) -> URL? = { _ in nil }
        private let baseFont = NoteFieldHTML.defaultFont()

        init(htmlText: Binding<String>, session: NoteFieldEditingSession, fieldIndex: Int) {
            self._htmlText = htmlText
            self.session = session
            self.fieldIndex = fieldIndex
        }

        func attach(textView: NSTextView) {
            self.textView = textView
        }

        func load(_ html: String, preservesSourceHTML: Bool) {
            guard let textView else { return }
            if preservesSourceHTML {
                textView.string = NoteFieldHTML.normalizeMathJax(html)
            } else {
                textView.textStorage?.setAttributedString(
                    NoteFieldHTML.attributedString(from: html, font: baseFont)
                )
            }
            lastHTML = html
            if !preservesSourceHTML {
                hydrateImages()
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
            session.attach(responder: self, fieldIndex: fieldIndex)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            session.detach(responder: self)
            commit()
        }

        func textDidChange(_ notification: Notification) {
            commit()
            session.refreshChrome()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            session.refreshChrome()
        }

        var canUndo: Bool { textView?.undoManager?.canUndo ?? false }
        var canRedo: Bool { textView?.undoManager?.canRedo ?? false }
        var currentStyle: NoteFieldHTML.Style {
            guard let textView else { return .init() }
            let attrs = textView.typingAttributes
            return NoteFieldHTML.style(from: attrs)
        }

        var currentListKind: NoteFieldHTML.ListKind {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return .none }
            let location = max(0, min(textView.selectedRange().location, storage.length - 1))
            return NoteFieldHTML.listKind(in: storage, at: location)
        }

        var currentAlignment: NoteFieldHTML.Alignment {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return .unspecified }
            let location = max(0, min(textView.selectedRange().location, storage.length - 1))
            return NoteFieldHTML.blockStyle(in: storage, at: location).alignment
        }

        var currentIndent: Int {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return 0 }
            let location = max(0, min(textView.selectedRange().location, storage.length - 1))
            return NoteFieldHTML.blockStyle(in: storage, at: location).indent
        }

        var isHTMLSource: Bool {
            session.htmlSourceFields.contains(fieldIndex)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard !isHTMLSource, replacementString == "\n", let storage = textView.textStorage else { return true }
            guard let selected = NoteFieldHTML.handleReturn(on: storage, range: range, font: baseFont) else {
                return true
            }
            textView.setSelectedRange(selected)
            commit()
            session.refreshChrome()
            return false
        }

        func perform(_ action: NoteFieldFormatAction) {
            guard let textView else { return }
            if isHTMLSource {
                switch action {
                case .undo, .redo, .toggleHTMLSource, .dismiss, .camera, .photoLibrary, .attach: break
                default: return
                }
            }
            switch action {
            case .undo: textView.undoManager?.undo()
            case .redo: textView.undoManager?.redo()
            case .bold: toggle(\.bold)
            case .italic: toggle(\.italic)
            case .underline: toggle(\.underline)
            case .strike: toggle(\.strike)
            case .superscript: toggle(\.superscript)
            case .subscript: toggle(\.subscript)
            case .code: toggle(\.code)
            case .math: wrapPlain(#"\("#, suffix: #"\)"#)
            case .clear: clearFormatting()
            case .list(let kind): toggleList(kind)
            case .align(let alignment): applyAlignment(alignment)
            case .indent: changeIndent(1)
            case .outdent: changeIndent(-1)
            case .toggleHTMLSource:
                commit()
                if session.htmlSourceFields.contains(fieldIndex) {
                    session.htmlSourceFields.remove(fieldIndex)
                } else {
                    session.htmlSourceFields.insert(fieldIndex)
                }
                isShowingHTMLSource = isHTMLSource
                load(htmlText, preservesSourceHTML: isHTMLSource)
            case .cloze: wrapCloze(increment: true)
            case .clozeSame: wrapCloze(increment: false)
            case .camera:
                session.perform(.camera)
            case .photoLibrary:
                session.perform(.photoLibrary)
            case .attach:
                session.perform(.attach)
            case .dismiss: textView.window?.makeFirstResponder(nil)
            }
            switch action {
            case .toggleHTMLSource, .camera, .photoLibrary, .attach: break
            default: commit()
            }
            session.refreshChrome()
        }

        func insertImage(filename: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let placeholder = NoteFieldHTML.imagePlaceholder(
                filename: filename,
                font: baseFont,
                style: currentStyle,
                listKind: currentListKind
            )
            storage.replaceCharacters(in: textView.selectedRange(), with: placeholder)
            commit()
            session.refreshChrome()
            hydrateImages()
        }

        func hydrateImages() {
            guard !isShowingHTMLSource, let textView, let storage = textView.textStorage else { return }
            var filenames: [String] = []
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                guard let attachment = value as? NoteFieldImageAttachment else { return }
                filenames.append(attachment.filename)
            }
            for filename in filenames {
                guard let url = resolveImageURL(filename) else { continue }
                if let cached = DownsampledImageLoader.cached(url: url, maxPixelSize: 1400) {
                    applyLoadedImage(cached, filename: filename)
                    continue
                }
                Task { [weak self] in
                    let image = await DownsampledImageLoader.load(url: url, maxPixelSize: 1400)
                    await MainActor.run {
                        self?.applyLoadedImage(image, filename: filename)
                    }
                }
            }
        }

        func applyLoadedImage(_ image: NSImage?, filename: String) {
            guard let image, let textView, let storage = textView.textStorage else { return }
            let framed = NoteFieldHTML.framedImage(image)
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                guard let attachment = value as? NoteFieldImageAttachment,
                      attachment.filename == filename else { return }
                attachment.image = framed
            }
            textView.needsLayout = true
            textView.needsDisplay = true
        }

        func insertSound(filename: String) {
            wrapPlain("[sound:\(filename)]", suffix: "")
            commit()
            session.refreshChrome()
        }

        fileprivate func commit() {
            guard let textView, let storage = textView.textStorage else { return }
            let encoded = isHTMLSource ? textView.string : NoteFieldHTML.encode(storage)
            lastHTML = encoded
            htmlText = encoded
        }

        private func toggleList(_ kind: NoteFieldHTML.ListKind) {
            guard let textView, let storage = textView.textStorage else { return }
            let selected = NoteFieldHTML.toggleListKind(
                on: storage,
                range: textView.selectedRange(),
                kind: kind,
                font: baseFont
            )
            textView.setSelectedRange(selected)
        }

        private func applyAlignment(_ alignment: NoteFieldHTML.Alignment) {
            guard let textView, let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            NoteFieldHTML.applyAlignment(on: storage, range: selected, alignment: alignment, font: baseFont)
            textView.setSelectedRange(selected)
        }

        private func changeIndent(_ delta: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            NoteFieldHTML.changeIndent(on: storage, range: textView.selectedRange(), delta: delta, font: baseFont)
        }

        private func wrapCloze(increment: Bool) {
            wrapPlain("{{c\(session.nextClozeOrdinal(increment: increment))::", suffix: "}}")
        }

        private func wrapPlain(_ prefix: String, suffix: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            let attrs = NoteFieldHTML.attributes(for: currentStyle, font: baseFont, listKind: currentListKind)
            storage.insert(NSAttributedString(string: suffix, attributes: attrs), at: selected.location + selected.length)
            storage.insert(NSAttributedString(string: prefix, attributes: attrs), at: selected.location)
            textView.setSelectedRange(NSRange(
                location: selected.location + (prefix as NSString).length,
                length: selected.length
            ))
        }

        private func toggle(_ keyPath: WritableKeyPath<NoteFieldHTML.Style, Bool>) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            if range.length == 0 {
                var style = NoteFieldHTML.style(from: textView.typingAttributes)
                style[keyPath: keyPath].toggle()
                textView.typingAttributes = NoteFieldHTML.attributes(for: style, font: baseFont)
                return
            }
            let currentlyOn = traitIsUniformlyOn(storage, range: range, keyPath: keyPath)
            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                var style = NoteFieldHTML.style(from: attributes)
                style[keyPath: keyPath] = !currentlyOn
                storage.addAttributes(
                    NoteFieldHTML.attributes(for: style, font: baseFont),
                    range: subrange
                )
            }
            storage.endEditing()
        }

        private func clearFormatting() {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            let target = range.length > 0 ? range : NSRange(location: 0, length: storage.length)
            storage.setAttributes(
                NoteFieldHTML.attributes(for: .init(), font: baseFont),
                range: target
            )
        }

        private func traitIsUniformlyOn(
            _ attributed: NSAttributedString,
            range: NSRange,
            keyPath: KeyPath<NoteFieldHTML.Style, Bool>
        ) -> Bool {
            var allOn = true
            attributed.enumerateAttributes(in: range, options: []) { attributes, _, stop in
                if !NoteFieldHTML.style(from: attributes)[keyPath: keyPath] {
                    allOn = false
                    stop.pointee = true
                }
            }
            return allOn
        }
    }
}

#endif

private enum NoteFieldLayout {
    static let minHeight: CGFloat = 72
    static let maxHeight: CGFloat = 280
}
