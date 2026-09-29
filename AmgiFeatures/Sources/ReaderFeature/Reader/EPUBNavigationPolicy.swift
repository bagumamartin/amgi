#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Foundation

/// Navigation and subresource policy for reader WebViews.
///
/// A reader page is book content: untrusted XHTML that we render. Without a
/// policy, a `<script>`, `<iframe>`, or `window.location` inside an EPUB can
/// navigate the reader off the book, read anything inside the granted
/// read-access scope, or phone home. ATS already blocks plaintext `http://`
/// on iOS, but it does nothing on macOS and nothing at all for `file://`
/// navigation inside the scope we grant.
///
/// The decision is a pure function of the URL plus the page's read-access
/// root so it can be unit-tested without a live `WKWebView` — the same
/// approach `CardWebViewCoordinator` already uses for the note renderer.
enum EPUBNavigationPolicy: Equatable {
    case allow
    /// Cancel the load and hand the URL to the system (http/https links the
    /// author put in the book).
    case openExternally(URL)
    case cancel

    /// Full navigation policy.
    ///
    /// - Parameters:
    ///   - url: the navigation target. A nil URL (a malformed request) is
    ///     always cancelled.
    ///   - isMainFrame: false for `target=_blank` / `window.open`, which must
    ///     never be allowed to create an untracked second page.
    ///   - readAccessURL: root the page is allowed to read. `file:` URLs
    ///     outside it are refused, including `..` traversal out of the book.
    static func decide(
        url: URL?,
        isMainFrame: Bool,
        readAccessURL: URL?
    ) -> EPUBNavigationPolicy {
        // A secondary frame has no place in a book. Cancelling here covers
        // `target=_blank` and `window.open` without needing a WKUIDelegate.
        guard isMainFrame, let url else { return .cancel }

        switch url.scheme?.lowercased() {
        case "about":
            // `loadHTMLString` reports an about: URL for the initial load.
            return .allow
        case "file":
            guard let readAccessURL else { return .cancel }
            return isWithin(url: url, root: readAccessURL) ? .allow : .cancel
        case "http", "https":
            return .openExternally(url)
        case "javascript", "data", "blob", "file-unexpected":
            return .cancel
        default:
            // Unknown schemes (tel:, mailto:, custom app schemes) are not
            // something a book should be able to trigger from a tap.
            return .cancel
        }
    }

    /// Subresource policy. `decidePolicyFor navigationAction` never sees
    /// `<img>`/`<script src>`/`<link>` fetches, so remote and inline
    /// subresources need their own gate.
    static func allowsSubresource(
        url: URL,
        readAccessURL: URL?
    ) -> Bool {
        switch url.scheme?.lowercased() {
        case "file":
            guard let readAccessURL else { return false }
            return isWithin(url: url, root: readAccessURL)
        case "data":
            // Inline images/CSS are common in EPUBs and cannot exfiltrate.
            return true
        case "about":
            return true
        default:
            // No http(s) images, no fonts, no media, no XHR/websocket.
            return false
        }
    }

    /// Content-Security-Policy injected before the book's own markup is
    /// parsed.
    ///
    /// Injected by a user script at document start and *replaces* any
    /// book-authored CSP, since a permissive book-supplied policy would
    /// otherwise win by arriving first. `connect-src 'none'` is the token
    /// that matters most: it is what stops a book script from using
    /// fetch/XHR/beacon/WebSocket to exfiltrate the text it is displaying.
    static let contentSecurityPolicy = """
    default-src 'self' file: data:; \
    script-src 'self' 'unsafe-inline'; \
    style-src 'self' 'unsafe-inline' file: data:; \
    img-src 'self' file: data:; \
    font-src 'self' file: data:; \
    media-src 'self' file: data:; \
    connect-src 'none'; \
    frame-src 'none'; \
    child-src 'none'; \
    object-src 'none'; \
    base-uri 'none'; \
    form-action 'none'
    """

    /// User script that installs the CSP at document start. `data-amgi-csp`
    /// marks ours so a later pass can find and remove a book-authored one.
    ///
    /// The policy is interpolated into a **double**-quoted JS string: the
    /// policy itself is full of single quotes (`'self'`, `'unsafe-inline'`,
    /// `'none'`), so a single-quoted string would terminate early and throw
    /// a SyntaxError, leaving the page unprotected.
    static let contentSecurityPolicyScript = """
    (function() {
      try {
        var head = document.head || document.documentElement;
        if (!head) { return; }
        // Remove any policy the book shipped, including permissive ones, and
        // our own previous copy so repeated injection stays idempotent.
        var stale = document.querySelectorAll(
          'meta[http-equiv="Content-Security-Policy"], meta[data-amgi-csp]'
        );
        for (var i = 0; i < stale.length; i++) { stale[i].remove(); }
        var meta = document.createElement('meta');
        meta.setAttribute('http-equiv', 'Content-Security-Policy');
        meta.setAttribute('data-amgi-csp', '1');
        meta.setAttribute('content', "\(contentSecurityPolicy)");
        head.insertBefore(meta, head.firstChild);
      } catch (e) { /* never block rendering on a CSP failure */ }
    })();
    """

    /// Hand an author-placed link to the system. Only http(s) ever reaches
    /// here — the policy cancels every other scheme — so there is no scheme
    /// allowlist to bypass and no way for a book to reach a custom app scheme.
    static func openInSystem(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Path containment

extension EPUBNavigationPolicy {
    /// True when `url` resolves inside `root`.
    ///
    /// Compares standardized, symlink-resolved paths so neither `..`
    /// traversal nor a symlink planted in the extracted book can walk out of
    /// the directory we granted read access to. A trailing separator is
    /// handled so `…/book` matches `…/book/chapter.xhtml` but not
    /// `…/bookshelf/…`.
    static func isWithin(url: URL, root: URL) -> Bool {
        let rootPath = standardizedDirectoryPath(root)
        let targetPath = standardizedDirectoryPath(url)
        if targetPath == rootPath { return true }
        return targetPath.hasPrefix(rootPath + "/")
    }

    private static func standardizedDirectoryPath(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolved.path
        // `standardizedFileURL` drops a trailing slash for directories; make
        // the comparison explicit rather than relying on that.
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }
}
