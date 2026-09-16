// AmgiApp/Sources/Browse/BrowseInspector.swift
import SwiftUI
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import AmgiTheme
import AmgiCardWeb
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Trailing inspector for single selection (spec §5.8): Edit uses the
/// existing rich editor pipeline, Preview renders the REAL card via the
/// same WKWebView renderer review uses, Info surfaces scheduling facts.
/// On iPhone there is no trailing pane — sheets host the same tabs via
/// `BrowseDetailSheet`.
struct BrowseDetailTabs: View {
    @Environment(\.palette) private var palette

    let note: NoteRecord?
    let notetypeName: String?
    /// Cards-mode record for the Info tab (per-card facts).
    let infoCard: CardRecord?
    /// First card of the selected note — feeds Preview rendering.
    let firstCardID: CardID?
    let deckID: DeckID?
    let onSaved: () -> Void

    enum Tab: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
        case info = "Info"
    }

    // Clicking a row is a peek, not an edit session — Preview leads and
    // Edit is one tap away (desktop-Anki parity for the default view).
    @State private var tab: Tab = .preview

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            content
        }
        .background(palette.background)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .edit:
            if let note {
                NoteEditorView(note: note, deckID: deckID, onSave: onSaved)
                    .id(note.id)
            } else {
                Text("Select one row to edit its fields and tags.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case .preview:
            if let firstCardID {
                CardPreviewPane(cardId: firstCardID)
            } else {
                Text("Preview needs a card; switch to Cards mode or resolve the note's cards.")
                    .amgiFont(.body).foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case .info:
            CardInfoPane(card: infoCard)
        }
    }
}

// MARK: - Preview pane (real renderer)

struct CardPreviewPane: View {
    @Environment(\.palette) private var palette
    let cardId: CardID?

    struct Rendered: Equatable {
        let frontHTML: String
        let backHTML: String
        let css: String
    }

    @State private var rendered: Rendered?
    @State private var showAnswer = false
    @State private var failed = false

    @Dependency(\.cardRenderingService) private var rendering

    var body: some View {
        Group {
            if let rendered {
                ScrollView {
                    VStack(spacing: 12) {
                        flipCard(rendered)
                        Button(showAnswer ? "Show question" : "Show answer") {
                            withAnimation(AmgiMotion.quick) { showAnswer.toggle() }
                        }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 16)
                    }
                    .padding()
                }
            } else if failed {
                emptyState("Preview unavailable for this row.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: cardId) {
            await load()
        }
    }

    @ViewBuilder
    private func flipCard(_ rendered: Rendered) -> some View {
        BrowseCardPreview(
            html: showAnswer ? rendered.backHTML : rendered.frontHTML,
            css: rendered.css
        )
        .frame(minHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.hero))
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.hero)
                .strokeBorder(palette.separator, lineWidth: 1)
        )
    }

    private func load() async {
        guard let cardId else {
            failed = true
            return
        }
        do {
            // Sync FFI under the hood — hop off MainActor per the blocking-
            // FFI rule. `rendering` is Sendable, so its closure capture is
            // legal outside the actor.
            let renderer = rendering
            let card = try await Task.detached(priority: .userInitiated) {
                try renderer.renderCard(cardId)
            }.value
            rendered = Rendered(
                frontHTML: card.frontHTML,
                backHTML: card.backHTML,
                css: card.cardCSS
            )
            failed = false
        } catch {
            failed = true
        }
    }

    private func emptyState(_ text: String) -> some View {
        ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(text))
    }
}

private extension CardPreviewPane {
    // `firstCardID` is passed in directly; placeholder kept for symmetry.
}

// MARK: - Info pane (native facts; revlog history ships with engine rows)

struct CardInfoPane: View {
    @Environment(\.palette) private var palette
    /// Cards-mode rows hand a full record; notes-mode hands nil (info is
    /// per-card — desktop shows note's first card).
    let card: CardRecord?

    var body: some View {
        List {
            if let card {
                Section("Scheduling") {
                    factRow("Type", typeName(card.type))
                    factRow("Queue", queueName(card.queue))
                    factRow("Due", dueDescription(card))
                    if card.ivl > 0 {
                        factRow("Interval", "\(card.ivl)d")
                    }
                    if card.factor > 0 {
                        factRow("Ease factor", "\(card.factor.formatted(.number.precision(.fractionLength(1))))‰")
                    }
                    factRow("Reviews", "\(card.reps)")
                    factRow("Lapses", "\(card.lapses)")
                }
                Section("Identity") {
                    factRow("Card ID", "\(card.id.rawValue)")
                    factRow("Note ID", "\(card.nid.rawValue)")
                    factRow("Deck ID", "\(card.did.rawValue)")
                    if card.odid != DeckID(0) {
                        factRow("Original deck", "\(card.odid.rawValue)")
                        factRow("Original due", "\(card.odue)")
                    }
                }
                Section("Flags") {
                    factRow("Flag color", flagName(card.flags & 0b111))
                }
            } else {
                Text("Scheduling info is per-card. Switch to Cards mode or pick a specific card to inspect it.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(palette.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .monospacedDigit()
        }
        .amgiFont(.body)
    }

    private func typeName(_ type: Int16) -> String {
        switch type {
        case 0: "New"
        case 1: "Learning"
        case 2: "Review"
        case 3: "Relearning"
        default: "type \(type)"
        }
    }

    private func queueName(_ queue: Int16) -> String {
        switch queue {
        case ..<(-1): "Buried"
        case -1: "Suspended"
        case 0: "New"
        case 1...: "In learning/review"
        default: "queue \(queue)"
        }
    }

    private func dueDescription(_ card: CardRecord) -> String {
        switch card.type {
        case 0: "#\(card.due)"
        default:
            card.due > 86_400 ? "+\(card.due / 86_400)d" : "today (\(card.due))"
        }
    }

    private func flagName(_ flag: Int32) -> String {
        ["None", "Red", "Orange", "Green", "Blue", "Pink", "Turquoise", "Purple"][Int(flag)]
    }
}

#if canImport(WebKit)
import WebKit

/// Inspector-only card preview. Review's `CardWebView` lives in ReviewFeature,
/// which Browse cannot import (Review → Browse).
#if os(iOS)
private struct BrowseCardPreview: UIViewRepresentable {
    let html: String
    let css: String

    func makeCoordinator() -> BrowsePreviewAssetScheme {
        BrowsePreviewAssetScheme()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: CardAssetPath.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(wrapped, baseURL: CardAssetPath.cardBaseURL)
    }

    private var wrapped: String {
        let body = CardHTMLRewriter.rewrite(html)
        return """
        <html><head>\(CardAssetPath.mediaBaseTag())\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>img{max-width:100%;height:auto;border-radius:12px;} \(css)</style>\
        </head><body>\(body)</body></html>
        """
    }
}
#elseif os(macOS)
private struct BrowseCardPreview: NSViewRepresentable {
    let html: String
    let css: String

    func makeCoordinator() -> BrowsePreviewAssetScheme {
        BrowsePreviewAssetScheme()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: CardAssetPath.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(wrapped, baseURL: CardAssetPath.cardBaseURL)
    }

    private var wrapped: String {
        let body = CardHTMLRewriter.rewrite(html)
        return """
        <html><head>\(CardAssetPath.mediaBaseTag())\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>img{max-width:100%;height:auto;border-radius:12px;} \(css)</style>\
        </head><body>\(body)</body></html>
        """
    }
}
#endif

#if canImport(WebKit)
@MainActor
final class BrowsePreviewAssetScheme: NSObject, WKURLSchemeHandler {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @Dependency(\.mediaClient) private var mediaClient

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let mediaRoot = mediaClient.folderURL()
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
        tasks[key] = Task { [weak self] in
            let data = try? await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL, options: .mappedIfSafe)
            }.value
            guard let self, self.tasks[key] != nil, !Task.isCancelled else { return }
            self.tasks[key] = nil
            if let data {
                self.respond(to: urlSchemeTask, url: url, statusCode: 200, mimeType: mimeType, data: data)
            } else {
                self.respond(to: urlSchemeTask, url: url, statusCode: 404, data: Data())
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
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
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
}
#endif
#endif

