import SwiftUI
#if canImport(UIKit)
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let onComplete {
            controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif canImport(AppKit)
import AppKit

/// macOS counterpart of the iOS `UIActivityViewController` sheet. The picker
/// is anchored to the representable's view and dismissed by AppKit, so the
/// SwiftUI presentation state flips back via `onComplete`.
struct ShareSheet: NSViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = context.coordinator
            picker.show(relativeTo: .zero, of: controller.view, preferredEdge: .minY)
        }
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        let onComplete: (() -> Void)?

        init(onComplete: (() -> Void)?) {
            self.onComplete = onComplete
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose sharingService: NSSharingService?
        ) {
            onComplete?()
        }
    }
}
#endif
