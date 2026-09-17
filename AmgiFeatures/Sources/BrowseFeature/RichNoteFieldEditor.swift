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

    func makeUIView(context: Context) -> NoteFieldEditorContainer {
        let editor = NoteFieldTextView()
        editor.delegate = context.coordinator
        editor.isEditable = true
        editor.isSelectable = true
        editor.isScrollEnabled = true
        editor.backgroundColor = .clear
        editor.textContainer.lineFragmentPadding = 0
        editor.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        editor.font = NoteFieldHTML.defaultFont()
        editor.textColor = .label
        editor.adjustsFontForContentSizeCategory = true
        editor.allowsEditingTextAttributes = true
        let container = NoteFieldEditorContainer(editor: editor)
        context.coordinator.attach(textView: editor)
        context.coordinator.gutter = container.gutter
        context.coordinator.load(htmlText, preservesSourceHTML: preservesSourceHTML)

        let accessory = NoteFieldFormatAccessory { [weak coordinator = context.coordinator] action in
            coordinator?.session.perform(action)
        }
        editor.formatAccessory = accessory
        context.coordinator.accessory = accessory
        editor.accessoryEnabled = !session.hasHardwareKeyboard
        context.coordinator.installAssistantItems()
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NoteFieldEditorContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let editor = uiView.editor
        let gutterWidth = context.coordinator.isShowingHTMLSource ? NoteFieldEditorContainer.gutterWidth : 0
        let fitting = editor.sizeThatFits(CGSize(width: max(1, width - gutterWidth), height: .greatestFiniteMagnitude))
        let height = min(max(NoteFieldLayout.minHeight, fitting.height), NoteFieldLayout.maxHeight)
        editor.isScrollEnabled = fitting.height > NoteFieldLayout.maxHeight
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ uiView: NoteFieldEditorContainer, context: Context) {
        let editor = uiView.editor
        context.coordinator.fieldIndex = fieldIndex
        context.coordinator.session = session
        context.coordinator.palette = palette
        context.coordinator.resolveImageURL = { mediaClient.localURL($0) }
        editor.accessoryEnabled = !session.hasHardwareKeyboard
        context.coordinator.refreshAccessory()
        uiView.setGutterVisible(context.coordinator.isShowingHTMLSource)

        let source = session.htmlSourceFields.contains(fieldIndex)
        if source != context.coordinator.isShowingHTMLSource {
            context.coordinator.commit()
            context.coordinator.isShowingHTMLSource = source
            context.coordinator.load(htmlText, preservesSourceHTML: source)
            uiView.setGutterVisible(source)
            return
        }

        if context.coordinator.lastAppliedFocusGeneration != focusGeneration {
            context.coordinator.lastAppliedFocusGeneration = focusGeneration
            if fieldIndex == 0, focusGeneration > 0 {
                DispatchQueue.main.async { editor.becomeFirstResponder() }
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
        weak var gutter: UITextView?
        weak var accessory: NoteFieldFormatAccessory?
        /// Set while handling a typed `>` so the resulting change runs
        /// auto-close exactly once (programmatic inserts bypass the delegate).
        private var pendingAutoClose = false
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

        /// Character index of the tapped image attachment (apply target for
        /// the resize menu). Cleared on taps elsewhere.
        private var selectedImageIndex: Int?
        private var didInstallTap = false

        func attach(textView: NoteFieldTextView) {
            self.textView = textView
            guard !didInstallTap else { return }
            didInstallTap = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            textView.addGestureRecognizer(tap)
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView, !isShowingHTMLSource else {
                selectedImageIndex = nil
                session.selectedImage = nil
                session.refreshChrome()
                return
            }
            let point = recognizer.location(in: textView)
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            var fraction: CGFloat = 0
            let index = layoutManager.characterIndex(
                for: point, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )
            selectImageIfPresent(at: index, in: textView.attributedText)
        }

        private func selectImageIfPresent(at index: Int, in attributed: NSAttributedString) {
            guard let textView,
                  let info = NoteFieldHTML.imageInfo(in: attributed, at: index)
            else {
                selectedImageIndex = nil
                session.selectedImage = nil
                session.refreshChrome()
                refreshAccessory()
                return
            }
            selectedImageIndex = index
            session.selectedImage = SelectedFieldImage(
                filename: info.filename, widthAttr: info.width, heightAttr: info.height
            )
            textView.selectedRange = NSRange(location: index, length: 1)
            session.refreshChrome()
            refreshAccessory()
        }

        // MARK: - HTML source IDE

        /// Inserts the auto-close tag for a just-typed `>` when enabled.
        private func runAutoCloseIfPending() {
            guard pendingAutoClose, let textView else { return }
            pendingAutoClose = false
            let storage = textView.textStorage
            let cursor = textView.selectedRange.location
            guard cursor > 0, cursor <= storage.length,
                  (storage.string as NSString).character(at: cursor - 1) == 62 /* > */
            else { return }
            guard let close = NoteFieldHTML.autoCloseTag(
                in: storage.string as NSString, gtIndex: cursor - 1
            ) else { return }
            storage.mutableString.insert(close, at: cursor)
            textView.selectedRange = NSRange(location: cursor, length: 0)
        }

        /// Full syntax repaint without registering undo (typing stays one
        /// undoable unit; colors never pollute the undo stack).
        private func applySourceHighlight() {
            guard let textView, isShowingHTMLSource else { return }
            let selected = textView.selectedRange
            let offset = textView.contentOffset
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            textView.textStorage.setAttributedString(
                NoteFieldHTML.highlightSource(textView.textStorage.string, font: sourceMonoFont)
            )
            textView.selectedRange = NSRange(
                location: min(selected.location, textView.textStorage.length),
                length: 0
            )
            textView.contentOffset = offset
        }

        /// Highlights the open/close tag pair around the cursor (desktop
        /// matching-tags behavior). Cleared by the next full repaint.
        private func paintMatchingTags() {
            guard let textView, isShowingHTMLSource else { return }
            let cursor = textView.selectedRange.location
            guard let pair = NoteFieldHTML.matchingTagPair(
                in: textView.textStorage.string as NSString, cursor: cursor
            ) else { return }
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            #if canImport(UIKit)
            let mark = UIColor.systemYellow.withAlphaComponent(0.3)
            #else
            let mark = NSColor.systemYellow.withAlphaComponent(0.3)
            #endif
            textView.textStorage.addAttribute(.backgroundColor, value: mark, range: pair.open)
            textView.textStorage.addAttribute(.backgroundColor, value: mark, range: pair.close)
        }

        private func updateCursorStatus() {
            guard let textView, isShowingHTMLSource else {
                session.sourceCursor = nil
                return
            }
            let pos = NoteFieldHTML.lineColumn(
                in: textView.textStorage.string as NSString,
                index: textView.selectedRange.location
            )
            session.sourceCursor = (line: pos.line, column: pos.column)
        }

        /// Refreshes highlight + match + gutter + cursor after loads and edits.
        private func updateSourceChrome() {
            isRepainting = true
            applySourceHighlight()
            paintMatchingTags()
            isRepainting = false
            updateCursorStatus()
            updateGutter()
        }

        /// Rebuilds the gutter numbers and pins its offset to the editor.
        /// Exact by construction: source mode never wraps, so paragraphs and
        /// gutter rows are 1:1 (plus the phantom line after a trailing break).
        private func updateGutter() {
            guard let textView, let gutter, isShowingHTMLSource else {
                gutter?.isHidden = true
                return
            }
            gutter.isHidden = false
            let numbers = NoteFieldHTML.lineNumbers(for: textView.textStorage.string)
            gutter.attributedText = NSAttributedString(
                string: numbers,
                attributes: [
                    .font: sourceMonoFont,
                    .foregroundColor: UIColor.tertiaryLabel,
                ]
            )
            // Same font and top inset as the editor, so rows align 1:1.
            var inset = gutter.textContainerInset
            inset.top = textView.textContainerInset.top
            gutter.textContainerInset = inset
            var offset = gutter.contentOffset
            offset.y = textView.contentOffset.y
            gutter.contentOffset = offset
        }

        /// Applies (`width` px) or restores (nil) the tapped image's stored
        /// dimensions, then re-encodes on commit so the tag round-trips.
        private func applyImageSize(_ width: String?) {
            guard let textView, let index = selectedImageIndex else { return }
            let storage = NSMutableAttributedString(attributedString: textView.attributedText)
            guard NoteFieldHTML.setImageWidth(width, in: storage, at: index) else { return }
            textView.attributedText = storage
            textView.selectedRange = NSRange(location: index, length: 1)
            if let info = NoteFieldHTML.imageInfo(in: storage, at: index) {
                session.selectedImage = SelectedFieldImage(
                    filename: info.filename, widthAttr: info.width, heightAttr: info.height
                )
            }
            commit()
            session.refreshChrome()
            refreshAccessory()
        }

        private var sourceMonoFont: UIFont {
            UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        }

        func load(_ html: String, preservesSourceHTML: Bool) {
            guard let textView else { return }
            applyWrapping(htmlSource: preservesSourceHTML)
            let attributed: NSAttributedString
            if preservesSourceHTML {
                attributed = NoteFieldHTML.highlightSource(html, font: sourceMonoFont)
            } else {
                attributed = NoteFieldHTML.attributedString(from: html, font: baseFont)
            }
            textView.textStorage.setAttributedString(attributed)
            lastHTML = html
            if preservesSourceHTML {
                updateSourceChrome()
            } else {
                session.sourceCursor = nil
                hydrateImages()
            }
        }

        /// Source mode never wraps (one paragraph = one gutter row, matching
        /// desktop code editors); rich mode wraps at the view width.
        private func applyWrapping(htmlSource: Bool) {
            guard let textView else { return }
            if htmlSource {
                textView.textContainer.widthTracksTextView = false
                textView.textContainer.size = CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            } else {
                textView.textContainer.widthTracksTextView = true
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

        /// While true, storage mutations come from our own syntax repaint,
        /// not the user — delegate re-entry short-circuits.
        private var isRepainting = false

        func textViewDidChange(_ textView: UITextView) {
            guard !isRepainting else { return }
            if isShowingHTMLSource {
                runAutoCloseIfPending()
                isRepainting = true
                applySourceHighlight()
                paintMatchingTags()
                isRepainting = false
                updateCursorStatus()
                updateGutter()
            }
            commit()
            session.refreshChrome()
            refreshAccessory()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Keyboard-driven cursor moves off the tapped image drop the
            // resize target; taps manage it explicitly via handleTap.
            if let idx = selectedImageIndex,
               !NSLocationInRange(idx, textView.selectedRange) {
                selectedImageIndex = nil
                session.selectedImage = nil
            }
            if isShowingHTMLSource, !isRepainting {
                // Repaint the base first so the previous cursor's match
                // marks don't accumulate.
                isRepainting = true
                applySourceHighlight()
                paintMatchingTags()
                isRepainting = false
                updateCursorStatus()
            }
            session.refreshChrome()
            refreshAccessory()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isShowingHTMLSource,
                  let textView, scrollView === textView,
                  let gutter else { return }
            var offset = gutter.contentOffset
            offset.y = textView.contentOffset.y
            gutter.contentOffset = offset
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
            if isHTMLSource {
                // Arm auto-close for a freshly typed `>` (single-char insert).
                if text == ">", range.length == 0, session.htmlAutoCloseTags {
                    pendingAutoClose = true
                }
                return true
            }
            guard text == "\n" else { return true }
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
                case .undo, .redo, .toggleHTMLSource, .dismiss, .camera, .photoLibrary, .attach, .recordAudio: break
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
            case .mathBlock: wrapPlain(#"\["#, suffix: #"\]"#)
            case .mathLatex(let env): wrapPlain("\\begin{\(env)}\n", suffix: "\n\\end{\(env)}")
            case .textColor(let hex): applyTextColor(hex)
            case .highlight(let hex): applyHighlight(hex)
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
            case .recordAudio:
                session.perform(.recordAudio)
            case .imageSize(let width):
                applyImageSize(width)
            case .dismiss: textView.resignFirstResponder()
            }
            switch action {
            case .toggleHTMLSource, .camera, .photoLibrary, .attach, .recordAudio: break
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

        /// Applies (or clears, when hex is nil) the text color across the
        /// selection or typing attributes. Hex is normalized to `#rrggbb`
        /// so the HTML codec round-trips it through `<span style>`.
        private func applyTextColor(_ hex: String?) {
            guard let textView else { return }
            let normalized = hex.flatMap { NoteFieldHTML.normalizeHex($0) }
            let range = textView.selectedRange
            if range.length == 0 {
                var style = NoteFieldHTML.style(from: textView.typingAttributes)
                style.textColorHex = normalized
                textView.typingAttributes = NoteFieldHTML.attributes(for: style, font: baseFont)
                return
            }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                var style = NoteFieldHTML.style(from: attributes)
                style.textColorHex = normalized
                attributed.addAttributes(
                    NoteFieldHTML.attributes(for: style, font: baseFont),
                    range: subrange
                )
            }
            textView.attributedText = attributed
            textView.selectedRange = range
        }

        private func applyHighlight(_ hex: String?) {
            guard let textView else { return }
            let normalized = hex.flatMap { NoteFieldHTML.normalizeHex($0) }
            let range = textView.selectedRange
            if range.length == 0 {
                var style = NoteFieldHTML.style(from: textView.typingAttributes)
                style.highlightHex = normalized
                textView.typingAttributes = NoteFieldHTML.attributes(for: style, font: baseFont)
                return
            }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                var style = NoteFieldHTML.style(from: attributes)
                style.highlightHex = normalized
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

/// Container for the rich editor plus its HTML-source line-number gutter.
/// The gutter is a non-interactive, non-scrolling text view kept at the full
/// content height inside a clipped strip; the coordinator drives its text
/// and vertical offset. Source mode also disables line wrapping so one
/// paragraph is always exactly one gutter row.
final class NoteFieldEditorContainer: UIView {
    static let gutterWidth: CGFloat = 44

    let editor: NoteFieldTextView
    let gutter = UITextView()
    private var gutterWidthConstraint: NSLayoutConstraint!

    init(editor: NoteFieldTextView) {
        self.editor = editor
        super.init(frame: .zero)
        gutter.isEditable = false
        gutter.isSelectable = false
        // Scrolling stays enabled internally (user interaction off) so the
        // coordinator can pin the offset to the editor programmatically.
        gutter.isScrollEnabled = true
        gutter.isUserInteractionEnabled = false
        gutter.showsVerticalScrollIndicator = false
        gutter.showsHorizontalScrollIndicator = false
        gutter.backgroundColor = .clear
        gutter.textContainer.lineFragmentPadding = 0
        gutter.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 6)
        gutter.textAlignment = .right
        gutter.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(editor)
        clipsToBounds = true
        gutterWidthConstraint = gutter.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidthConstraint,
            editor.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        gutter.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setGutterVisible(_ visible: Bool) {
        gutter.isHidden = !visible
        gutterWidthConstraint.constant = visible ? Self.gutterWidth : 0
    }
}

#else

/// Native vertical ruler drawing 1-based line numbers for the HTML-source
/// editor. Scrolling stays correct by construction (rulers track their scroll
/// view), and wrapped continuation fragments draw blank so numbers stay
/// glued to paragraph starts — desktop code-editor parity.
final class SourceLineNumberRuler: NSRulerView {
    weak var sourceView: NSTextView?

    init(scrollView: NSScrollView, sourceView: NSTextView) {
        self.sourceView = sourceView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        guard let textView = sourceView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let storage = textView.textStorage else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Visible glyph range in container coordinates.
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphVisible = ns.length == 0
            ? NSRange(location: 0, length: 0)
            : layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let charVisible = layoutManager.characterRange(
            forGlyphRange: glyphVisible, actualGlyphRange: nil
        )
        // 1-based number of the first visible paragraph.
        var lineNo = ns.substring(to: min(charVisible.location, ns.length))
            .components(separatedBy: "\n").count
        ns.enumerateSubstrings(in: charVisible, options: .byParagraphs) { [self] _, _, enclosing, _ in
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: enclosing, actualCharacterRange: nil
            )
            var drewNumber = false
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                var point = NSPoint(
                    x: 0,
                    y: fragment.minY + textView.textContainerOrigin.y
                )
                point = self.convert(point, from: textView)
                guard rect.intersects(NSRect(x: rect.minX, y: point.y - 2, width: rect.width, height: 18)) else { return }
                if !drewNumber {
                    let label = "\(lineNo)" as NSString
                    let width = label.size(withAttributes: attrs).width
                    label.draw(
                        at: NSPoint(x: rect.maxX - width - 6, y: point.y + 2),
                        withAttributes: attrs
                    )
                    drewNumber = true
                }
            }
            lineNo += 1
        }
        // Phantom line after a trailing newline.
        if ns.length > 0, ns.character(at: ns.length - 1) == 10 /* \n */ {
            var point = NSPoint(x: 0, y: layoutManager.usedRect(for: textContainer).maxY + textView.textContainerOrigin.y)
            point = self.convert(point, from: textView)
            if rect.intersects(NSRect(x: rect.minX, y: point.y - 2, width: rect.width, height: 18)) {
                let label = "\(lineNo)" as NSString
                let width = label.size(withAttributes: attrs).width
                label.draw(
                    at: NSPoint(x: rect.maxX - width - 6, y: point.y + 2),
                    withAttributes: attrs
                )
            }
        }
        _ = full
    }
}

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
        let ruler = SourceLineNumberRuler(scrollView: scrollView, sourceView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = preservesSourceHTML
        scrollView.rulersVisible = preservesSourceHTML
        context.coordinator.attach(textView: textView)
        context.coordinator.load(htmlText, preservesSourceHTML: preservesSourceHTML)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let textView = nsView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        // Source mode never wraps: don't clamp the container or measurement
        // (and don't disturb the nowrap setting either).
        if !context.coordinator.isShowingHTMLSource {
            textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
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

        private var selectedImageIndex: Int?
        private var didInstallClick = false

        func attach(textView: NSTextView) {
            self.textView = textView
            guard !didInstallClick else { return }
            didInstallClick = true
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            textView.addGestureRecognizer(click)
        }

        @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let textView, !isShowingHTMLSource,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else {
                selectedImageIndex = nil
                session.selectedImage = nil
                session.refreshChrome()
                return
            }
            let point = recognizer.location(in: textView)
            var fraction: CGFloat = 0
            let glyph = layoutManager.glyphIndex(
                for: point, in: textContainer,
                fractionOfDistanceThroughGlyph: &fraction
            )
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            guard let storage = textView.textStorage,
                  let info = NoteFieldHTML.imageInfo(in: storage, at: index)
            else {
                selectedImageIndex = nil
                session.selectedImage = nil
                session.refreshChrome()
                return
            }
            selectedImageIndex = index
            session.selectedImage = SelectedFieldImage(
                filename: info.filename, widthAttr: info.width, heightAttr: info.height
            )
            textView.setSelectedRange(NSRange(location: index, length: 1))
            session.refreshChrome()
        }

        private func applyImageSize(_ width: String?) {
            guard let textView, let storage = textView.textStorage,
                  let index = selectedImageIndex else { return }
            guard NoteFieldHTML.setImageWidth(width, in: storage, at: index) else { return }
            textView.setSelectedRange(NSRange(location: index, length: 1))
            if let info = NoteFieldHTML.imageInfo(in: storage, at: index) {
                session.selectedImage = SelectedFieldImage(
                    filename: info.filename, widthAttr: info.width, heightAttr: info.height
                )
            }
            commit()
            session.refreshChrome()
        }

        private var pendingAutoClose = false

        private var sourceMonoFont: NSFont {
            NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        }

        func load(_ html: String, preservesSourceHTML: Bool) {
            guard let textView else { return }
            applyWrapping(htmlSource: preservesSourceHTML)
            toggleRuler(preservesSourceHTML)
            if preservesSourceHTML {
                let source = NoteFieldHTML.normalizeMathJax(html)
                textView.textStorage?.setAttributedString(
                    NoteFieldHTML.highlightSource(source, font: sourceMonoFont)
                )
                textView.typingAttributes = [
                    .font: sourceMonoFont,
                    .foregroundColor: NSColor.labelColor,
                ]
            } else {
                textView.textStorage?.setAttributedString(
                    NoteFieldHTML.attributedString(from: html, font: baseFont)
                )
            }
            lastHTML = html
            if preservesSourceHTML {
                updateSourceChrome()
            } else {
                session.sourceCursor = nil
                hydrateImages()
            }
        }

        /// Source mode scrolls horizontally (matches iOS: one paragraph is
        /// one visual line); rich mode wraps at the view width.
        private func applyWrapping(htmlSource: Bool) {
            guard let textView, let container = textView.textContainer else { return }
            if htmlSource {
                textView.isHorizontallyResizable = true
                container.widthTracksTextView = false
                container.containerSize = CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                textView.enclosingScrollView?.hasHorizontalScroller = true
            } else {
                textView.isHorizontallyResizable = false
                container.widthTracksTextView = true
                textView.enclosingScrollView?.hasHorizontalScroller = false
            }
        }

        private func toggleRuler(_ visible: Bool) {
            guard let scrollView = textView?.enclosingScrollView else { return }
            scrollView.hasVerticalRuler = visible
            scrollView.rulersVisible = visible
            scrollView.verticalRulerView?.needsDisplay = true
        }

        // MARK: - HTML source IDE

        private func runAutoCloseIfPending() {
            guard pendingAutoClose,
                  let storage = textView?.textStorage,
                  let textView else { return }
            pendingAutoClose = false
            let cursor = textView.selectedRange().location
            let ns = storage.string as NSString
            guard cursor > 0, cursor <= ns.length,
                  ns.character(at: cursor - 1) == 62 /* > */,
                  let close = NoteFieldHTML.autoCloseTag(in: ns, gtIndex: cursor - 1)
            else { return }
            storage.mutableString.insert(close, at: cursor)
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
        }

        private func applySourceHighlight() {
            guard let textView, let storage = textView.textStorage,
                  isShowingHTMLSource else { return }
            let selected = textView.selectedRange()
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            storage.setAttributedString(
                NoteFieldHTML.highlightSource(storage.string, font: sourceMonoFont)
            )
            let clamped = min(selected.location, storage.length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }

        private func paintMatchingTags() {
            guard let textView, let storage = textView.textStorage,
                  isShowingHTMLSource else { return }
            guard let pair = NoteFieldHTML.matchingTagPair(
                in: storage.string as NSString,
                cursor: textView.selectedRange().location
            ) else { return }
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            let mark = NSColor.systemYellow.withAlphaComponent(0.3)
            storage.addAttribute(.backgroundColor, value: mark, range: pair.open)
            storage.addAttribute(.backgroundColor, value: mark, range: pair.close)
        }

        private func updateCursorStatus() {
            guard let textView, let storage = textView.textStorage,
                  isShowingHTMLSource else {
                session.sourceCursor = nil
                return
            }
            let pos = NoteFieldHTML.lineColumn(
                in: storage.string as NSString,
                index: textView.selectedRange().location
            )
            session.sourceCursor = (line: pos.line, column: pos.column)
        }

        private func updateSourceChrome() {
            isRepainting = true
            applySourceHighlight()
            paintMatchingTags()
            isRepainting = false
            updateCursorStatus()
            textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
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

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            if isShowingHTMLSource,
               affectedRanges.count == 1,
               replacementStrings?.count == 1,
               replacementStrings?[0] == ">",
               affectedRanges[0].rangeValue.length == 0,
               session.htmlAutoCloseTags {
                pendingAutoClose = true
            }
            return true
        }

        private var isRepainting = false

        func textDidChange(_ notification: Notification) {
            guard !isRepainting else { return }
            if isShowingHTMLSource {
                runAutoCloseIfPending()
                isRepainting = true
                applySourceHighlight()
                paintMatchingTags()
                isRepainting = false
                updateCursorStatus()
                textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
            commit()
            session.refreshChrome()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let idx = selectedImageIndex,
               let range = (notification.object as? NSTextView)?.selectedRange(),
               !NSLocationInRange(idx, range) {
                selectedImageIndex = nil
                session.selectedImage = nil
            }
            if isShowingHTMLSource, !isRepainting {
                isRepainting = true
                applySourceHighlight()
                paintMatchingTags()
                isRepainting = false
                updateCursorStatus()
            }
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
                case .undo, .redo, .toggleHTMLSource, .dismiss, .camera, .photoLibrary, .attach, .recordAudio: break
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
            case .mathBlock: wrapPlain(#"\["#, suffix: #"\]"#)
            case .mathLatex(let env): wrapPlain("\\begin{\(env)}\n", suffix: "\n\\end{\(env)}")
            case .textColor(let hex): applyTextColor(hex)
            case .highlight(let hex): applyHighlight(hex)
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
            case .recordAudio:
                session.perform(.recordAudio)
            case .imageSize(let width):
                applyImageSize(width)
            case .dismiss: textView.window?.makeFirstResponder(nil)
            }
            switch action {
            case .toggleHTMLSource, .camera, .photoLibrary, .attach, .recordAudio: break
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

        private func applyTextColor(_ hex: String?) {
            guard let textView, let storage = textView.textStorage else { return }
            let normalized = hex.flatMap { NoteFieldHTML.normalizeHex($0) }
            let range = textView.selectedRange()
            if range.length == 0 {
                var style = NoteFieldHTML.style(from: textView.typingAttributes)
                style.textColorHex = normalized
                textView.typingAttributes = NoteFieldHTML.attributes(for: style, font: baseFont)
                return
            }
            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                var style = NoteFieldHTML.style(from: attributes)
                style.textColorHex = normalized
                storage.addAttributes(
                    NoteFieldHTML.attributes(for: style, font: baseFont),
                    range: subrange
                )
            }
            storage.endEditing()
        }

        private func applyHighlight(_ hex: String?) {
            guard let textView, let storage = textView.textStorage else { return }
            let normalized = hex.flatMap { NoteFieldHTML.normalizeHex($0) }
            let range = textView.selectedRange()
            if range.length == 0 {
                var style = NoteFieldHTML.style(from: textView.typingAttributes)
                style.highlightHex = normalized
                textView.typingAttributes = NoteFieldHTML.attributes(for: style, font: baseFont)
                return
            }
            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                var style = NoteFieldHTML.style(from: attributes)
                style.highlightHex = normalized
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
