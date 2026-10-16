#if os(iOS)
import UIKit
import WebKit

/// The chapter's web view, which adds the reader's items to WebKit's own
/// selection menu.
///
/// WebKit builds that menu by walking the responder chain with
/// `buildMenu(with:)`, and the web view sits on that chain above its content
/// view, so overriding it here is how the Anki actions join Copy, Translate
/// and Share in one menu at the selection.
final class ReaderWebView: WKWebView {
    /// Supplied by the chapter controller, which knows the selection and the
    /// draft stack.
    var selectionMenuElements: (() -> [UIMenuElement])?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let elements = selectionMenuElements?() else { return }
        ReaderSystemSelectionMenu.merge(elements, into: builder)
    }
}
#endif
