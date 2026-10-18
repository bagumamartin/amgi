import AnkiKit
import AnkiServices
import AmgiCardWeb
import Dependencies
import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Pictures of cards as they look in review, for Browse's grid and
/// waterfall. Two hidden web views render question sides one at a time and
/// snapshot them; the pictures are cached, so scrolling shows images rather
/// than live web pages (the cost of one WKWebView per tile).
@MainActor
final class CardThumbnailRenderer: NSObject {
    static let shared = CardThumbnailRenderer()

    /// Points wide the card is laid out at; tiles scale the picture down.
    static let renderWidth: CGFloat = 320
    /// Waterfall pictures stop growing here, so one long card can't fill a
    /// column.
    static let maximumHeight: CGFloat = 560

    @Dependency(\.cardRenderingService) private var rendering

    private let cache = NSCache<NSString, PlatformImage>()
    private var workers: [Worker] = []
    private var queue: [Job] = []
    private var host: AnyObject?

    private struct Job {
        let key: String
        let cardID: CardID
        let isDarkMode: Bool
        let continuation: CheckedContinuation<PlatformImage?, Never>
    }

    private override init() {
        cache.countLimit = 400
        super.init()
    }

    /// The card's question side as a picture, or nil when it can't render.
    /// `version` (the note's modification time) keys the cache, so an edit
    /// re-renders.
    func image(for cardID: CardID, version: Int64, isDarkMode: Bool) async -> PlatformImage? {
        let key = "\(cardID.rawValue)-\(version)-\(isDarkMode ? 1 : 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await withCheckedContinuation { continuation in
            queue.append(Job(key: key as String, cardID: cardID, isDarkMode: isDarkMode, continuation: continuation))
            pump()
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func cachedImage(for cardID: CardID, version: Int64, isDarkMode: Bool) -> PlatformImage? {
        cache.object(forKey: "\(cardID.rawValue)-\(version)-\(isDarkMode ? 1 : 0)" as NSString)
    }

    private func pump() {
        #if canImport(WebKit)
        if workers.isEmpty { workers = (0..<2).map { _ in Worker(host: hostView()) } }
        for worker in workers where !worker.isBusy {
            guard !queue.isEmpty else { return }
            let job = queue.removeFirst()
            worker.isBusy = true
            Task {
                let image = await render(job, on: worker)
                job.continuation.resume(returning: image)
                worker.isBusy = false
                pump()
            }
        }
        #else
        while !queue.isEmpty { queue.removeFirst().continuation.resume(returning: nil) }
        #endif
    }

    #if canImport(WebKit)
    private func render(_ job: Job, on worker: Worker) async -> PlatformImage? {
        let renderer = rendering
        let cardID = job.cardID
        guard let card = try? await Task.detached(priority: .utility, operation: {
            try renderer.renderCard(cardID)
        }).value else { return nil }
        let html = BrowsePreviewHTML.wrappedDocument(
            html: BrowsePreviewHTML.displayHTML(
                front: card.frontHTML, back: card.backHTML, showAnswer: false, answerOnly: false
            ),
            css: card.cardCSS,
            isDarkMode: job.isDarkMode,
            cardOrdinal: 0
        )
        return await worker.snapshot(html: html)
    }

    /// WebKit only paints a web view that is in a window. The workers live
    /// off-screen in the app's window (iOS) or a hidden one (macOS).
    private func hostView() -> AnyObject? {
        if let host { return host }
        #if os(iOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.windows.first
        host = window
        return window
        #elseif os(macOS)
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: Self.renderWidth, height: Self.maximumHeight),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        host = window
        return window
        #endif
    }

    @MainActor
    private final class Worker: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        var isBusy = false
        private var finished: CheckedContinuation<Void, Never>?
        private let scheme = BrowsePreviewAssetScheme()

        init(host: AnyObject?) {
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(scheme, forURLScheme: CardAssetPath.scheme)
            config.mediaTypesRequiringUserActionForPlayback = .all
            webView = WKWebView(
                frame: CGRect(x: -10_000, y: 0, width: CardThumbnailRenderer.renderWidth, height: 200),
                configuration: config
            )
            super.init()
            webView.navigationDelegate = self
            #if os(iOS)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.isUserInteractionEnabled = false
            (host as? UIWindow)?.insertSubview(webView, at: 0)
            #elseif os(macOS)
            webView.setValue(false, forKey: "drawsBackground")
            (host as? NSWindow)?.contentView?.addSubview(webView)
            #endif
        }

        func snapshot(html: String) async -> PlatformImage? {
            // Start short: scrollHeight never reports less than the frame.
            webView.frame.size = CGSize(width: CardThumbnailRenderer.renderWidth, height: 120)
            await withCheckedContinuation { continuation in
                finished = continuation
                webView.loadHTMLString(html, baseURL: CardAssetPath.cardBaseURL)
            }
            // Let images decode before the picture is taken.
            try? await Task.sleep(for: .milliseconds(60))
            let measured = (try? await webView.evaluateJavaScript("document.documentElement.scrollHeight")) as? Double
            let height = min(max(CGFloat(measured ?? 200), 120), CardThumbnailRenderer.maximumHeight)
            webView.frame.size = CGSize(width: CardThumbnailRenderer.renderWidth, height: height)
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: CardThumbnailRenderer.renderWidth, height: height)
            return try? await webView.takeSnapshot(configuration: config)
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { resume() }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { resume() }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            MainActor.assumeIsolated { resume() }
        }

        private func resume() {
            finished?.resume()
            finished = nil
        }
    }
    #endif
}
