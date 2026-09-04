public import SwiftUI
#if os(iOS)
import UIKit

public struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    public init(items: [Any], onComplete: (() -> Void)? = nil) {
        self.items = items
        self.onComplete = onComplete
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let onComplete {
            controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#elseif os(macOS)

public struct ShareSheet: View {
    let items: [Any]
    var onComplete: (() -> Void)?

    public init(items: [Any], onComplete: (() -> Void)? = nil) {
        self.items = items
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 16) {
            if let url = items.compactMap({ $0 as? URL }).first {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button("Done") { onComplete?() }
        }
        .padding(24)
        .frame(minWidth: 240)
    }
}

#endif
