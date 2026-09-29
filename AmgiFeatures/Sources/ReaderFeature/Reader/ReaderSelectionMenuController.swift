#if os(iOS)
import AmgiTheme
import Foundation
import UIKit

/// Presents the long-press selection menu over a chapter's web view.
///
/// `UIEditMenuInteraction` is the supported way to put a custom menu on a text
/// selection; `UIMenuController` is deprecated and does not compose with
/// WebKit's callout. The interaction is anchored to the web view so it tracks
/// the selection's drag handles.
@MainActor
final class ReaderSelectionMenuController: NSObject, UIEditMenuInteractionDelegate {
    /// `UIEditMenuInteraction.delegate` is get-only, so the interaction has to
    /// be constructed *after* `super.init()` with `self` already available.
    private var interaction: UIEditMenuInteraction!
    private weak var presenter: ReaderSelectionMenuPresenting?
    private var payload: ReaderSelectionPayload?
    private weak var anchorView: UIView?

    /// - Parameter anchorView: the view the menu is presented on, i.e. the
    ///   web view the selection lives in.
    init(presenter: ReaderSelectionMenuPresenting, anchorView: UIView) {
        self.presenter = presenter
        self.anchorView = anchorView
        super.init()
        let interaction = UIEditMenuInteraction(delegate: self)
        self.interaction = interaction
        anchorView.addInteraction(interaction)
    }

    /// Shows the menu for a fresh selection.
    ///
    /// Safe to call repeatedly: WebKit fires `selectionchange` for every caret
    /// move while the handles are dragged, so the menu is only presented when
    /// the selected text actually changed. Re-presenting on every tick would
    /// make the menu flicker under the user's finger.
    func present(for payload: ReaderSelectionPayload) {
        let isNewSelection = self.payload?.text != payload.text
        self.payload = payload
        guard isNewSelection, anchorView != nil else { return }
        // Deferred a tick so WebKit has finished presenting its own selection
        // UI; presenting in the same runloop turn makes the two fight.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
            interaction.presentEditMenu(with: config)
        }
    }

    func dismiss() {
        payload = nil
        interaction.dismissMenu()
    }

    // MARK: - UIEditMenuInteractionDelegate

    nonisolated func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        MainActor.assumeIsolated { buildMenu() }
    }

    nonisolated func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willPresentMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        MainActor.assumeIsolated {
            animator.addAnimations {}
        }
    }

    nonisolated func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        MainActor.assumeIsolated {
            // Drop the payload so a later, unrelated presentation cannot reuse
            // a stale selection.
            payload = nil
            animator.addAnimations {}
        }
    }

    @MainActor
    private func buildMenu() -> UIMenu? {
        guard let payload, let presenter else { return nil }
        // One UIAction per entry so the system can title-case and lay them out.
        // Unavailable actions are omitted rather than disabled: a greyed-out
        // "Look Up" reads as a bug.
        let actions: [UIAction] = ReaderSelectionMenu.availableActions(for: payload).map { action in
            UIAction(
                title: ReaderSelectionMenu.title(for: action),
                image: UIImage(systemName: ReaderSelectionMenu.systemImage(for: action))
            ) { [weak self] _ in
                guard let self else { return }
                presenter.readerSelectionMenu(action, payload: payload)
                dismiss()
            }
        }
        guard !actions.isEmpty else { return nil }
        return UIMenu(children: actions)
    }
}
#endif
