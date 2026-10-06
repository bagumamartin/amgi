import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// First-page snapshot for an EPUB with no embedded cover.
///
/// Most EPUBs open onto their cover, so rendering the first chapter's top at
/// cover proportions captures it without any OPF cover metadata — and when
/// the first page is not a cover, it still beats a generic tile. Falls back
/// to `placeholder` when the chapter cannot load or the snapshot times out.
///
/// Snapshots render once per book per session (memory cache) and only for
/// cells actually on screen: both library sections are lazy, so an
/// off-screen coverless book costs nothing.
struct EPUBFirstPageThumbnail<Placeholder: View>: View {
    let source: EPUBFirstPageSource
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var snapshot: PlatformCoverImage?

    var body: some View {
        Group {
            if let snapshot {
                EPUBSnapshotImageView(image: snapshot)
            } else {
                placeholder()
            }
        }
        .task(id: source) {
            snapshot = await EPUBFirstPageRenderer.snapshot(for: source)
        }
    }
}

#if os(macOS)
private struct EPUBSnapshotImageView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
    }
}
#else
private struct EPUBSnapshotImageView: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
    }
}
#endif

/// Rendering + cache live outside the generic view: a generic type cannot
/// hold static stored properties, and referencing its static members from a
/// detached task would capture the placeholder's metatype.
private enum EPUBFirstPageRenderer {
    // NSCache is thread-safe; the `unsafe` is only about Swift not knowing that.
    nonisolated(unsafe) private static let cache: NSCache<NSString, PlatformCoverImage> = {
        let cache = NSCache<NSString, PlatformCoverImage>()
        cache.countLimit = 40
        return cache
    }()

    /// Rendered viewport. Matches the 2:3 cover frame so the snapshot fills
    /// it with no letterboxing.
    private static let viewportSize = CGSize(width: 400, height: 600)
    /// Pixels across for the snapshot output: crisp at 3x in the grid without
    /// holding a full-resolution raster per book.
    private static let snapshotWidth: CGFloat = 800
    /// Layout/fonts settle delay after load finishes, before snapshotting.
    private static let settleNanoseconds: UInt64 = 400_000_000
    /// A chapter that cannot load or snapshot in this window is abandoned to
    /// the placeholder rather than stalling the cell.
    private static let timeoutNanoseconds: UInt64 = 10_000_000_000

    @MainActor
    static func snapshot(for source: EPUBFirstPageSource) async -> PlatformCoverImage? {
        let key = source.contentURL.standardizedFileURL.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: PlatformCoverImage?
        do {
            image = try await withThrowingTaskGroup(of: PlatformCoverImage?.self) { group in
                group.addTask { await render(source: source) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            return nil
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Loads the chapter in an off-screen WebView and snapshots its top. The
    /// WebView is never added to a window: a non-zero frame is enough for
    /// layout to run.
    @MainActor
    private static func render(source: EPUBFirstPageSource) async -> PlatformCoverImage? {
        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewportSize))
        #if !os(macOS)
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        #endif
        let delegate = SnapshotNavigationDelegate()
        webView.navigationDelegate = delegate
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            delegate.onDone = { continuation.resume(returning: $0) }
            webView.loadFileURL(source.contentURL, allowingReadAccessTo: source.readAccessURL)
        }
        guard loaded else { return nil }
        try? await Task.sleep(nanoseconds: settleNanoseconds)
        guard !Task.isCancelled else { return nil }
        var configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: viewportSize)
        configuration.snapshotWidth = snapshotWidth as NSNumber
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

private final class SnapshotNavigationDelegate: NSObject, WKNavigationDelegate {
    var onDone: ((Bool) -> Void)?
    private var settled = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(success: true)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        settle(success: false)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        settle(success: false)
    }

    private func settle(success: Bool) {
        guard !settled else { return }
        settled = true
        onDone?(success)
    }
}
