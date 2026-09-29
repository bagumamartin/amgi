import AmgiReader
import Foundation
import Observation

/// Lets the SwiftUI layer drive the live page controller.
///
/// The paging host is a `UIViewControllerRepresentable` / `NSViewRepresentable`
/// whose coordinator is created and owned by the framework, so the view has no
/// handle on the current chapter's controller. Rather than thread a reference
/// through the representable's value semantics, both sides hold this bus: the
/// view sets a request, the coordinator picks it up on the main actor and
/// answers.
///
/// Requests are one-shot and cleared on fulfilment, so a second tap while a
/// capture is in flight cannot be silently dropped or answered twice.
@Observable
@MainActor
final class ReaderPageCommands {
    /// Set by the view; fulfilled by the coordinator with an anchor for the
    /// current viewport, or nil when the page cannot produce one.
    var anchorRequest: (@MainActor (ReaderSourceAnchor?) -> Void)?

    /// Set by the view; the coordinator pushes the stored marks for the newly
    /// shown chapter.
    var marksRefresh: (() -> Void)?

    /// Supplied by the view: the marks for the chapter currently loading.
    ///
    /// Injected rather than resolved from the store here, because the page
    /// controller is created by the framework and has no way to reach the
    /// annotation store. Applied on `didFinish` — the token spans do not exist
    /// before then, so an earlier call would silently match nothing.
    var markProvider: (@MainActor () async -> [[String: Any]])?

    /// A mark requested from the selection menu. One-shot: consumed by the
    /// next `updateUIViewController` pass so it cannot be applied twice.
    struct SelectionMarkRequest {
        let kind: ReaderAnnotation.Kind
        let anchor: ReaderSourceAnchor?
        let excerpt: String
    }

    var selectionMarkRequest: SelectionMarkRequest?

    func requestSelectionMark(_ request: SelectionMarkRequest) {
        selectionMarkRequest = request
    }

    /// The marks the view most recently asked the page to draw. Held here so a
    /// chapter change can re-apply them without a round trip to the store.
    var lastAppliedMarks: [[String: Any]] = []

    func requestAnchor(_ completion: @escaping @MainActor (ReaderSourceAnchor?) -> Void) {
        anchorRequest = completion
    }

    func fulfilAnchorRequest(with anchor: ReaderSourceAnchor?) {
        let pending = anchorRequest
        anchorRequest = nil
        pending?(anchor)
    }
}
