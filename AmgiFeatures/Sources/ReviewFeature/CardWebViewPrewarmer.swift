import SwiftUI
import WebKit
import AmgiCardWeb
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Keeps one fully configured, frame-loaded `WKWebView` ready for the first
/// HTML review card. WebKit's WebContent/GPU/Networking processes take
/// seconds to cold-start (launch logs: GPU 1.8s, WebContent 1.8–3.7s,
/// Networking 2.3s) and the old flow paid that cost *after* the user tapped
/// Study, staring at a blank card well. Warming while the user browses decks
/// moves the entire spawn out of the critical path.
///
/// Single-use handoff: `take()` gives both halves to `CardWebView`'s
/// representable conformance — the prewarmed coordinator becomes the
/// SwiftUI coordinator, so frame-load state (page signature, isPageLoaded,
/// pendingUpdateScript) carries over untouched, and its nil callbacks are
/// filled by the first `applyCardUpdate`. A frame loaded under a stale
/// appearance self-heals through the existing page-signature reload.
@MainActor
final class CardWebViewPrewarmer {
    static let shared = CardWebViewPrewarmer()

    private var stored: CardWebViewCoordinator?
    private var isPrewarming = false

    #if os(iOS)
    private var memoryWarningToken: NSObjectProtocol?
    #endif

    private init() {
        #if os(iOS)
        // An unadopted webview holds a live WebContent process (~tens of MB).
        // Under memory pressure the pool is disposable — the fallback path
        // recreates everything, just slower. Nilling the coordinator's
        // webview breaks its retain cycle so both actually deallocate.
        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stored?.prewarmedWebView = nil
                self?.stored = nil
                self?.isPrewarming = false
            }
        }
        #endif
    }

    // No deinit removal of the observer: this type is a `static let shared`
    // singleton that lives as long as the process, so the token never needs
    // unwinding — and a nonisolated deinit could not touch the non-Sendable
    // token property under Swift 6 isolation rules anyway.

    /// Idempotent and cheap to call from any screen-appear path: the WKWebView
    /// object is created synchronously (trivial cost), while the expensive
    /// process spawns happen out-of-process and never block the main thread.
    func prewarmIfNeeded() {
        guard stored == nil, !isPrewarming else { return }
        isPrewarming = true
        defer { isPrewarming = false }

        let coordinator = CardWebViewCoordinator()
        CardWebView.attachPrewarmedFrame(to: coordinator)
        stored = coordinator
    }

    /// Consumes the pooled pair, or nil when empty (caller falls back to
    /// inline creation — still benefiting from the warm process pool).
    func take() -> CardWebViewCoordinator? {
        defer { stored = nil }
        return stored
    }
}
