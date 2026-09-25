import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiCardWeb
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Preview sheet for uncommitted (unsaved) card templates, using
/// `CardRenderingService` for the actual HTML and a small native WebKit host
/// for display. Showing the returned HTML as `Text` made tags and CSS look
/// like source code; the WebKit host gives the editor a real card surface on
/// both iOS and macOS.
struct TemplatePreviewSheet: View {
    @Dependency(\.cardRenderingService) private var cardRenderingService
    @Dependency(\.mediaClient) private var mediaClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let title: String
    let emptyMessage: String
    let notetype: Notetype
    let loadSampleFields: () async throws -> [String]

    @State private var selectedTemplateIndex: Int
    @State private var previewSide: CardPreviewSide = .front
    @State private var sampleFields: [String]?
    @State private var renderedFrontHTML = ""
    @State private var renderedBackHTML = ""
    @State private var renderedCSS = ""
    @State private var isLoading = false
    @State private var isEmptyCard = false
    @State private var errorMessage: String?

    init(
        title: String,
        emptyMessage: String,
        notetype: Notetype,
        initialTemplateIndex: Int = 0,
        loadSampleFields: @escaping () async throws -> [String]
    ) {
        self.title = title
        self.emptyMessage = emptyMessage
        self.notetype = notetype
        self.loadSampleFields = loadSampleFields
        let normalized = notetype.templates.indices.contains(initialTemplateIndex) ? initialTemplateIndex : 0
        _selectedTemplateIndex = State(initialValue: normalized)
    }

    private var currentTemplateName: String {
        guard notetype.templates.indices.contains(selectedTemplateIndex) else {
            return "No template selected."
        }
        return notetype.templates[selectedTemplateIndex].name
    }

    private var currentHTML: String {
        previewSide == .front ? renderedFrontHTML : renderedBackHTML
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TemplatePreviewHeader(
                    currentTemplateName: currentTemplateName,
                    previewSide: $previewSide
                )
                TemplatePreviewBody(
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    isEmptyCard: isEmptyCard,
                    emptyMessage: emptyMessage,
                    html: currentHTML,
                    css: renderedCSS,
                    cardOrdinal: selectedTemplateIndex,
                    mediaFolder: mediaClient.folderURL()
                )
            }
            .background(palette.surfaceElevated)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await loadAndRenderPreview() }
            .onChange(of: selectedTemplateIndex) {
                Task { await renderPreview() }
            }
            .onKeyPress { press in
                guard press.key == .escape else { return .ignored }
                dismiss()
                return .handled
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
                .amgiToolbarTextButton()
                .keyboardShortcut(.cancelAction)
        }
    }
}

private extension TemplatePreviewSheet {
    @MainActor
    func loadAndRenderPreview() async {
        do {
            sampleFields = try await loadSampleFields()
            await renderPreview()
        } catch {
            isLoading = false
            isEmptyCard = false
            renderedFrontHTML = ""
            renderedBackHTML = ""
            renderedCSS = ""
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func renderPreview() async {
        guard notetype.templates.indices.contains(selectedTemplateIndex) else {
            isLoading = false
            isEmptyCard = false
            errorMessage = "No template selected."
            renderedFrontHTML = ""
            renderedBackHTML = ""
            renderedCSS = ""
            return
        }

        guard let fields = sampleFields else {
            await loadAndRenderPreview()
            return
        }

        isLoading = true
        defer { isLoading = false }

        let cardRenderingService = self.cardRenderingService
        let notetype = self.notetype
        let templateIndex = selectedTemplateIndex

        do {
            let rendered = try await Task.detached(priority: .userInitiated) {
                try cardRenderingService.renderUncommittedCard(
                    notetype,
                    templateIndex,
                    fields
                )
            }.value

            renderedFrontHTML = rendered.frontHTML
            renderedBackHTML = rendered.backHTML
            renderedCSS = rendered.cardCSS
            isEmptyCard = rendered.frontHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && rendered.backHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            errorMessage = nil
        } catch {
            isEmptyCard = false
            renderedFrontHTML = ""
            renderedBackHTML = ""
            renderedCSS = ""
            errorMessage = error.localizedDescription
        }
    }
}

enum CardPreviewSide: CaseIterable {
    case front
    case back

    var label: String {
        switch self {
        case .front: return "Front"
        case .back: return "Back"
        }
    }
}

struct TemplatePreviewHeader: View {
    let currentTemplateName: String
    @Binding var previewSide: CardPreviewSide

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text(currentTemplateName)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textSecondary)
                .accessibilityLabel("Template: \(currentTemplateName)")

            Picker("Preview side", selection: $previewSide) {
                ForEach(CardPreviewSide.allCases, id: \.self) { side in
                    Text(side.label).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityLabel("Preview side")
        }
        .padding()
    }
}

struct TemplatePreviewBody: View {
    let isLoading: Bool
    let errorMessage: String?
    let isEmptyCard: Bool
    let emptyMessage: String
    let html: String
    let css: String
    let cardOrdinal: Int
    let mediaFolder: URL?

    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Rendering card…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Rendering card")
            } else if let errorMessage {
                placeholder(systemImage: "exclamationmark.triangle", text: errorMessage, tint: palette.warning)
            } else if isEmptyCard {
                placeholder(systemImage: "rectangle.slash", text: emptyMessage, tint: palette.textTertiary)
            } else {
                TemplateHTMLPreview(
                    html: html,
                    css: css,
                    cardOrdinal: cardOrdinal,
                    mediaFolder: mediaFolder
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private extension TemplatePreviewBody {
    func placeholder(systemImage: String, text: String, tint: Color) -> some View {
        VStack(spacing: AmgiSpacing.sm) {
            Image(systemName: systemImage)
                .amgiFont(.sectionHeading)
                .foregroundStyle(tint)
            Text(text)
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
    }
}

/// A minimal, reusable WebKit surface for rendered card HTML. It deliberately
/// does not execute navigation away from the preview document; card content is
/// untrusted, while the shared AmgiCardWeb rewriter and asset scheme resolve
/// relative media against the active profile's media folder.
struct TemplateHTMLPreview: View {
    let html: String
    let css: String
    var cardOrdinal: Int = 0
    var mediaFolder: URL?

    @Environment(\.colorScheme) private var colorScheme

    private var document: String {
        TemplatePreviewDocument.document(
            html: html,
            css: css,
            cardOrdinal: cardOrdinal,
            isDarkMode: colorScheme == .dark
        )
    }

    private var contentSignature: String {
        "\(html.hashValue)|\(css.hashValue)|\(cardOrdinal)|\(colorScheme == .dark)"
    }

    var body: some View {
        #if os(iOS)
        TemplateHTMLPreviewHost(
            document: document,
            contentSignature: contentSignature,
            mediaFolder: mediaFolder
        )
            .accessibilityLabel("Rendered card preview")
        #elseif os(macOS)
        TemplateHTMLPreviewHost(
            document: document,
            contentSignature: contentSignature,
            mediaFolder: mediaFolder
        )
            .accessibilityLabel("Rendered card preview")
        #else
        Text(html)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

/// Kept separate from the SwiftUI wrapper so both UIKit and AppKit use the
/// same document and security policy.
enum TemplatePreviewDocument {
    static func document(
        html: String,
        css: String,
        cardOrdinal: Int = 0,
        isDarkMode: Bool
    ) -> String {
        let textColor = isDarkMode ? "#f5f5f5" : "#1a1a1a"
        let secondaryColor = isDarkMode ? "rgba(255,255,255,0.62)" : "rgba(0,0,0,0.62)"
        let colorScheme = isDarkMode ? "dark" : "light"
        let body = CardHTMLRewriter.rewrite(html)
        let bodyClasses = isDarkMode
            ? "card card\(max(0, cardOrdinal) + 1) nightMode night_mode"
            : "card card\(max(0, cardOrdinal) + 1)"
        let htmlClasses = isDarkMode ? "nightMode night_mode" : ""
        return """
        <!doctype html>
        <html class="\(htmlClasses)"><head>
        \(CardAssetPath.mediaBaseTag())
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: \(colorScheme); --preview-fg: \(textColor); --preview-secondary: \(secondaryColor); }
        html, body { background: transparent; }
        body {
            color: var(--preview-fg);
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 18px;
            line-height: 1.5;
            margin: 20px 24px 32px;
            overflow-wrap: anywhere;
        }
        img, video, audio { max-width: 100%; height: auto; }
        .cloze { font-weight: 600; color: #6da3ff; }
        \(css)
        </style>
        <script>
        function amgiPlay(id) {
            var element = document.getElementById(id);
            if (!element) return;
            element.currentTime = 0;
            element.play();
        }
        </script>
        </head><body class="\(bodyClasses)">\(body)</body></html>
        """
    }
}

#if canImport(WebKit)
@MainActor
private final class TemplatePreviewNavigationDelegate: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    var signature: String?
    var mediaRoot: URL?

    private var assetTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(mediaRoot: URL?) {
        self.mediaRoot = mediaRoot
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // A rendered card is a document, not a browser. Relative resources are
        // loaded by WebKit without a navigation callback; user-initiated links
        // must not replace the preview or navigate to a local file.
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased()
        guard scheme == "about" || scheme == CardAssetPath.scheme else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let fileURL = CardAssetPath.resolve(
            url: url,
            mediaRoot: mediaRoot,
            bundleRoot: Bundle.main.resourceURL
        ) else {
            respond(to: urlSchemeTask, url: url, statusCode: 204, data: Data())
            return
        }

        let key = ObjectIdentifier(urlSchemeTask)
        let mimeType = CardAssetPath.mimeType(for: fileURL)
        assetTasks[key] = Task { [weak self] in
            let data = try? await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL, options: .mappedIfSafe)
            }.value
            guard let self,
                  self.assetTasks[key] != nil,
                  !Task.isCancelled else { return }
            self.assetTasks[key] = nil
            if let data {
                self.respond(to: urlSchemeTask, url: url, statusCode: 200, mimeType: mimeType, data: data)
            } else {
                self.respond(to: urlSchemeTask, url: url, statusCode: 404, data: Data())
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        assetTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private func respond(
        to task: any WKURLSchemeTask,
        url: URL,
        statusCode: Int,
        mimeType: String = "text/plain",
        data: Data
    ) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": String(data.count),
            ]
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

#if os(iOS)
@MainActor
private struct TemplateHTMLPreviewHost: UIViewRepresentable {
    let document: String
    let contentSignature: String
    let mediaFolder: URL?

    func makeCoordinator() -> TemplatePreviewNavigationDelegate {
        TemplatePreviewNavigationDelegate(mediaRoot: mediaFolder)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: CardAssetPath.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let signature = "\(contentSignature)|\(mediaFolder?.path ?? "")"
        context.coordinator.mediaRoot = mediaFolder
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        webView.loadHTMLString(document, baseURL: mediaFolder)
    }
}
#elseif os(macOS)
@MainActor
private struct TemplateHTMLPreviewHost: NSViewRepresentable {
    let document: String
    let contentSignature: String
    let mediaFolder: URL?

    func makeCoordinator() -> TemplatePreviewNavigationDelegate {
        TemplatePreviewNavigationDelegate(mediaRoot: mediaFolder)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: CardAssetPath.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let signature = "\(contentSignature)|\(mediaFolder?.path ?? "")"
        context.coordinator.mediaRoot = mediaFolder
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        webView.loadHTMLString(document, baseURL: mediaFolder)
    }
}
#endif
#endif

/// A live preview used by the wide Mac/iPad template editor. It shares the
/// same renderer and WebKit surface as the sheet, but stays visible beside
/// the source while the user types.
struct TemplateEditorLivePreview: View {
    let notetype: Notetype
    let templateIndex: Int
    let loadSampleFields: () async throws -> [String]

    @Dependency(\.cardRenderingService) private var cardRenderingService
    @Dependency(\.mediaClient) private var mediaClient
    @Environment(\.palette) private var palette
    @State private var side: CardPreviewSide = .front
    @State private var rendered: RenderedCard?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private struct RenderID: Hashable {
        let notetype: Notetype
        let templateIndex: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live preview")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Picker("Preview side", selection: $side) {
                    ForEach(CardPreviewSide.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 190)
            }
            .padding(12)

            Divider()

            Group {
                if isLoading {
                    ProgressView("Rendering…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let rendered {
                    TemplateHTMLPreview(
                        html: side == .front ? rendered.frontHTML : rendered.backHTML,
                        css: rendered.cardCSS,
                        cardOrdinal: templateIndex,
                        mediaFolder: mediaClient.folderURL()
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .task(id: RenderID(notetype: notetype, templateIndex: templateIndex)) {
            await render()
        }
    }

    @MainActor
    private func render() async {
        isLoading = true
        errorMessage = nil
        guard notetype.templates.indices.contains(templateIndex) else {
            rendered = nil
            errorMessage = "No template selected."
            isLoading = false
            return
        }
        do {
            // Source edits arrive one keystroke at a time. Debounce the
            // backend render so holding a key does not queue a full card
            // render for every character.
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let fields = try await loadSampleFields()
            let service = cardRenderingService
            let schema = notetype
            let index = templateIndex
            rendered = try await Task.detached(priority: .userInitiated) {
                try service.renderUncommittedCard(schema, index, fields)
            }.value
        } catch is CancellationError {
            return
        } catch {
            rendered = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let notetype = Notetype(
        id: NotetypeID(1),
        name: "Basic",
        fields: [Notetype.Field(ord: 0, name: "Front")],
        templates: [Notetype.Template(ord: 0, name: "Card 1")]
    )
    let _ = prepareDependencies {
        $0.cardRenderingService.renderUncommittedCard = { _, _, _ in
            RenderedCard(
                frontHTML: "<p>Rendered front</p>",
                backHTML: "<p>Rendered back</p>",
                cardCSS: ".card { color: rebeccapurple; }"
            )
        }
    }
    return NavigationStack {
        TemplatePreviewSheet(
            title: "Rendered preview",
            emptyMessage: "This card has no content to preview.",
            notetype: notetype,
            loadSampleFields: { ["Front"] }
        )
    }
}
#endif
