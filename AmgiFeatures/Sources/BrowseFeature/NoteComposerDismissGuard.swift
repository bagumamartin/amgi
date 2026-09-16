import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Intercepts a sheet swipe-to-dismiss so the host can confirm instead of
/// dropping in-progress note text. SwiftUI has no `onDismissAttempt`.
struct NoteComposerDismissGuard: ViewModifier {
    var isBlocked: Bool
    var onAttempt: () -> Void

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background {
                DismissAttemptProbe(isBlocked: isBlocked, onAttempt: onAttempt)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            #endif
            .interactiveDismissDisabled(isBlocked)
    }
}

#if os(iOS)
private struct DismissAttemptProbe: UIViewRepresentable {
    var isBlocked: Bool
    var onAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isBlocked: isBlocked, onAttempt: onAttempt)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isBlocked = isBlocked
        context.coordinator.onAttempt = onAttempt
        context.coordinator.install(from: uiView)
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var isBlocked: Bool
        var onAttempt: () -> Void
        private weak var hooked: UIPresentationController?

        init(isBlocked: Bool, onAttempt: @escaping () -> Void) {
            self.isBlocked = isBlocked
            self.onAttempt = onAttempt
        }

        func install(from view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard let controller = Self.presentedController(from: view) else { return }
                if hooked !== controller.presentationController {
                    controller.presentationController?.delegate = self
                    hooked = controller.presentationController
                }
            }
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isBlocked
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isBlocked { onAttempt() }
        }

        private static func presentedController(from view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    var cursor: UIViewController? = controller
                    while let node = cursor {
                        if node.presentingViewController != nil { return node }
                        cursor = node.parent
                    }
                }
                responder = current.next
            }
            return nil
        }
    }
}
#endif
