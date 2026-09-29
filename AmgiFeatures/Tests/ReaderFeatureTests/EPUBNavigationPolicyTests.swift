import Foundation
import Testing
@testable import ReaderFeature

@Suite("EPUB reader navigation policy")
struct EPUBNavigationPolicyTests {
    private let bookRoot = URL(fileURLWithPath: "/private/var/containers/Book/App/EPUBRoot")

    // MARK: Schemes

    @Test("http(s) links are handed to the system, never loaded in the reader")
    func httpLinksOpenExternally() {
        for raw in ["https://example.com/a", "http://example.com"] {
            let url = URL(string: raw)!
            #expect(
                EPUBNavigationPolicy.decide(
                    url: url,
                    isMainFrame: true,
                    readAccessURL: bookRoot
                ) == .openExternally(url)
            )
        }
    }

    @Test("script and opaque schemes are always cancelled")
    func dangerousSchemesCancelled() {
        for raw in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "blob:https://example.com/abc",
            "tel:+15551234",
            "mailto:someone@example.com",
            "amgi://something",
        ] {
            let url = URL(string: raw)!
            #expect(
                EPUBNavigationPolicy.decide(
                    url: url,
                    isMainFrame: true,
                    readAccessURL: bookRoot
                ) == .cancel,
                "expected \(raw) to be cancelled"
            )
        }
    }

    @Test("a nil URL is cancelled rather than treated as allowed")
    func nilURLCancelled() {
        #expect(
            EPUBNavigationPolicy.decide(
                url: nil,
                isMainFrame: true,
                readAccessURL: bookRoot
            ) == .cancel
        )
    }

    // MARK: file scope

    @Test("file URLs inside the granted read scope are allowed")
    func fileURLsInsideScopeAllowed() {
        let chapter = bookRoot.appendingPathComponent("OEBPS/Text/ch1.xhtml")
        #expect(
            EPUBNavigationPolicy.decide(
                url: chapter,
                isMainFrame: true,
                readAccessURL: bookRoot
            ) == .allow
        )
    }

    @Test("file URLs outside the granted read scope are cancelled")
    func fileURLsOutsideScopeCancelled() {
        let outside = URL(fileURLWithPath: "/etc/passwd")
        #expect(
            EPUBNavigationPolicy.decide(
                url: outside,
                isMainFrame: true,
                readAccessURL: bookRoot
            ) == .cancel
        )
    }

    @Test("a missing read scope cancels every file URL")
    func nilReadScopeCancelsFileURLs() {
        let chapter = bookRoot.appendingPathComponent("OEBPS/ch1.xhtml")
        #expect(
            EPUBNavigationPolicy.decide(
                url: chapter,
                isMainFrame: true,
                readAccessURL: nil
            ) == .cancel
        )
    }

    @Test("traversal out of the book is cancelled even though it starts inside")
    func traversalOutOfScopeCancelled() {
        let escaping = bookRoot
            .appendingPathComponent("OEBPS/Text/../../../../etc/passwd")
        #expect(
            EPUBNavigationPolicy.decide(
                url: escaping,
                isMainFrame: true,
                readAccessURL: bookRoot
            ) == .cancel
        )
    }

    @Test("a sibling directory sharing the root's prefix is not inside it")
    func siblingPrefixIsNotInside() {
        // `/…/EPUBRootEvil` starts with `/…/EPUBRoot` as a raw string, but is
        // a different directory. A naive hasPrefix check would allow it.
        let sibling = URL(fileURLWithPath: "/private/var/containers/Book/App/EPUBRootEvil/secret.txt")
        #expect(EPUBNavigationPolicy.isWithin(url: sibling, root: bookRoot) == false)
    }

    // MARK: Frames

    @Test("a secondary frame is cancelled even for an otherwise-allowed URL")
    func secondaryFrameCancelled() {
        let chapter = bookRoot.appendingPathComponent("OEBPS/ch1.xhtml")
        #expect(
            EPUBNavigationPolicy.decide(
                url: chapter,
                isMainFrame: false,
                readAccessURL: bookRoot
            ) == .cancel
        )
        // Covers target=_blank and window.open from book content.
        #expect(
            EPUBNavigationPolicy.decide(
                url: URL(string: "https://example.com")!,
                isMainFrame: false,
                readAccessURL: bookRoot
            ) == .cancel
        )
    }

    // MARK: Subresources

    @Test("remote subresources are blocked but local and data ones are not")
    func subresourcePolicy() {
        let local = bookRoot.appendingPathComponent("OEBPS/Images/cover.jpg")
        #expect(EPUBNavigationPolicy.allowsSubresource(url: local, readAccessURL: bookRoot))
        #expect(
            EPUBNavigationPolicy.allowsSubresource(
                url: URL(string: "data:image/png;base64,AAAA")!,
                readAccessURL: bookRoot
            )
        )
        for raw in [
            "https://tracker.example.com/pixel.gif",
            "http://insecure.example.com/style.css",
            "https://example.com/app.js",
        ] {
            #expect(
                EPUBNavigationPolicy.allowsSubresource(
                    url: URL(string: raw)!,
                    readAccessURL: bookRoot
                ) == false,
                "expected \(raw) to be blocked as a subresource"
            )
        }
    }

    @Test("a local subresource outside the scope is blocked")
    func subresourceOutsideScopeBlocked() {
        let outside = URL(fileURLWithPath: "/etc/hosts")
        #expect(EPUBNavigationPolicy.allowsSubresource(url: outside, readAccessURL: bookRoot) == false)
    }

    // MARK: CSP

    @Test("the injected policy denies network egress and framing")
    func contentSecurityPolicyDeniesEgress() {
        let csp = EPUBNavigationPolicy.contentSecurityPolicy
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("frame-src 'none'"))
        #expect(csp.contains("object-src 'none'"))
        #expect(csp.contains("base-uri 'none'"))
        #expect(csp.contains("form-action 'none'"))
    }

    /// The policy above is worthless unless WebKit actually calls it.
    ///
    /// WebKit declares the handler as
    /// `@escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void`.
    /// Writing plain `@escaping` still compiles — as a *"nearly matches"*
    /// **warning** — and WebKit then never calls the method. The reader runs
    /// with no navigation policy at all, so this asserts the exact declaration
    /// in every coordinator that implements it.
    @Test("every reader coordinator declares decidePolicyFor with WebKit's exact signature")
    func policyIsActuallyInvokedByWebKit() throws {
        let coordinators = [
            "EPUBChapterPageController.swift",
            "EPUBPageViewControllerHost+macOS.swift",
            "ChapterWebView.swift",
        ]
        let required =
            "decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void"
        // A plain `@escaping` handler is the exact shape that compiles to a
        // warning and is never invoked.
        let forbidden = "decisionHandler: @escaping (WKNavigationActionPolicy) -> Void"

        var foundAny = false
        for name in coordinators {
            let source = try String(
                contentsOf: EPUBReaderInjectionScriptTests.readerSource(name),
                encoding: .utf8
            )
            let implementations = source.components(
                separatedBy: "decidePolicyFor navigationAction: WKNavigationAction"
            ).count - 1
            #expect(
                implementations > 0,
                "\(name) has no decidePolicyFor implementation at all"
            )
            foundAny = foundAny || implementations > 0
            #expect(
                !source.contains(forbidden),
                """
                \(name) declares decidePolicyFor with a plain @escaping handler. \
                That satisfies nothing at runtime: WebKit will never call it.
                """
            )
            let correctlyDeclared = source
                .components(separatedBy: "decidePolicyFor navigationAction: WKNavigationAction")
                .dropFirst()
                .filter { $0.contains(required) }
                .count
            #expect(
                correctlyDeclared == implementations,
                """
                \(name): \(implementations) decidePolicyFor implementation(s) but \
                \(correctlyDeclared) with WebKit's exact handler type.
                """
            )
        }
        #expect(foundAny, "no decidePolicyFor implementation was found anywhere")
    }

    @Test("the CSP script strips any book-authored policy before installing ours")
    func contentSecurityPolicyScriptReplacesBookPolicy() {
        let script = EPUBNavigationPolicy.contentSecurityPolicyScript
        // Must remove stale metas, not just append.
        #expect(script.contains("meta[http-equiv=\"Content-Security-Policy\"]"))
        #expect(script.contains("stale[i].remove()"))
        // The policy is full of single quotes, so it must be interpolated into
        // a double-quoted JS string or the script is a SyntaxError and the
        // page ends up with no CSP at all.
        #expect(script.contains("meta.setAttribute('content', \""))
        #expect(script.contains("connect-src 'none'"))
    }

    /// The whole point of the quoting above: the generated script has to be
    /// syntactically valid JavaScript. JavaScriptCore can prove that, so a
    /// green run means the script was actually parsed.
    @Test("the generated CSP script parses as JavaScript")
    func contentSecurityPolicyScriptIsValidJavaScript() {
        switch JSValidator.check(EPUBNavigationPolicy.contentSecurityPolicyScript) {
        case .valid:
            break
        case .invalid(let detail):
            Issue.record("CSP script is not valid JavaScript:\n\(detail)")
        case .skipped(let reason):
            Issue.record("CSP script could not be validated: \(reason)")
        }
    }
}
