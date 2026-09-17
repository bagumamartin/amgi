// AmgiApp/Sources/Browse/BrowseInspector.swift
import SwiftUI
import AmgiUI
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
/// Previous/next stepping for the Preview pane (desktop previewer parity).
struct BrowsePreviewNav {
    let ids: [Int64]
    let currentID: Int64?
    let onSelect: (Int64) async -> Void

    var currentIndex: Int? {
        guard let currentID else { return nil }
        return ids.firstIndex(of: currentID)
    }
    var canPrev: Bool { (currentIndex ?? 0) > 0 }
    var canNext: Bool { guard let i = currentIndex else { return false }; return i + 1 < ids.count }
}

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
    /// Optional result navigation (wired on split layouts; compact pushes
    /// one detail at a time and leaves this nil).
    var previewNav: BrowsePreviewNav?

    enum Tab: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
        case info = "Info"
    }

    // Clicking a row is a peek, not an edit session — Preview leads and
    // Edit is one tap away (desktop-Anki parity for the default view).
    @State private var tab: Tab = .preview
    /// Persistent Back Side Only (desktop previewer option).
    @AppStorage("browse.preview.backSideOnly") private var backSideOnly = false

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

    private var markState: Bool {
        note?.tags.split(separator: " ")
            .contains { $0.caseInsensitiveCompare("marked") == .orderedSame } == true
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
                CardPreviewPane(
                    cardId: firstCardID,
                    backSideOnly: backSideOnly,
                    nav: previewNav,
                    markIndicator: markState,
                    flagValue: infoCard.map { $0.flags & 0b111 }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Toggle("Back", isOn: $backSideOnly)
                            .toggleStyle(.button)
                            .help("Back Side Only")
                    }
                }
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
    /// Desktop Back Side Only: show the answer side without the question step.
    var backSideOnly = false
    var nav: BrowsePreviewNav?
    var markIndicator = false
    var flagValue: Int32?

    struct Rendered: Equatable {
        let frontHTML: String
        let backHTML: String
        let css: String
    }

    @State private var rendered: Rendered?
    @State private var showAnswer = false
    @State private var failed = false
    /// Bumps to force the WebView to reload (audio replay + explicit
    /// playback lifecycle: replay re-issues the HTML load so `<audio>`
    /// autoplays again instead of dangling).
    @State private var replayToken = 0

    @Dependency(\.cardRenderingService) private var rendering

    var body: some View {
        Group {
            if let rendered {
                ScrollView {
                    VStack(spacing: 12) {
                        indicatorRow
                        navRow
                        flipCard(rendered)
                        HStack(spacing: 12) {
                            if !backSideOnly {
                                Button(showAnswer ? "Show question" : "Show answer") {
                                    withAnimation(AmgiMotion.quick) { showAnswer.toggle() }
                                }
                                .buttonStyle(.bordered)
                            }
                            Button {
                                replayToken += 1
                            } label: {
                                Label("Replay Audio", systemImage: "speaker.wave.2")
                            }
                            .buttonStyle(.bordered)
                        }
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
            showAnswer = backSideOnly
            await load()
        }
        .onChange(of: backSideOnly) { _, new in
            if new { showAnswer = true }
        }
    }

    @ViewBuilder
    private var indicatorRow: some View {
        if markIndicator || (flagValue ?? 0) != 0 {
            HStack(spacing: 8) {
                if markIndicator {
                    Label("Marked", systemImage: "star.fill")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.customStudyBadge)
                }
                if let flag = flagValue, flag != 0 {
                    Label(flagName(flag), systemImage: "flag.fill")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var navRow: some View {
        if let nav {
            HStack {
                Button {
                    Task { await step(nav, by: -1) }
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(!nav.canPrev)
                Spacer()
                if let idx = nav.currentIndex {
                    Text("\(idx + 1) / \(nav.ids.count)")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    Task { await step(nav, by: 1) }
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .disabled(!nav.canNext)
            }
            .buttonStyle(.bordered)
        }
    }

    private func step(_ nav: BrowsePreviewNav, by delta: Int) async {
        guard let idx = nav.currentIndex else { return }
        let next = idx + delta
        guard nav.ids.indices.contains(next) else { return }
        await nav.onSelect(nav.ids[next])
    }

    private func flagName(_ flag: Int32) -> String {
        ["", "Red", "Orange", "Green", "Blue", "Pink", "Turquoise", "Purple"][Int(flag & 0b111)]
    }

    @ViewBuilder
    private func flipCard(_ rendered: Rendered) -> some View {
        BrowseCardPreview(
            html: showAnswer ? rendered.backHTML : rendered.frontHTML,
            css: rendered.css,
            replayToken: replayToken
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

// MARK: - Info pane (native facts + review history + FSRS)

struct CardInfoPane: View {
    @Environment(\.palette) private var palette
    /// Cards-mode rows hand a full record; notes-mode hands nil (info is
    /// per-card — desktop shows note's first card).
    let card: CardRecord?

    @State private var stats: CardStatsInfo?
    @State private var statsFailed = false
    @Dependency(\.cardClient) private var cards

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
                if let stats {
                    if stats.stability != nil || stats.difficulty != nil || stats.retrievabilityPct != nil {
                        Section("FSRS Memory") {
                            if let s = stats.stability {
                                factRow("Stability", String(format: "%.2f days", s))
                            }
                            if let d = stats.difficulty {
                                factRow("Difficulty", String(format: "%.1f%%", d * 100))
                            }
                            if let r = stats.retrievabilityPct {
                                factRow("Retrievability", String(format: "%.1f%%", r))
                            }
                        }
                    }
                    Section("Review History (\(stats.revlog.count))") {
                        if stats.revlog.isEmpty {
                            Text("No reviews logged yet.")
                                .amgiFont(.body)
                                .foregroundStyle(palette.textSecondary)
                        } else {
                            ForEach(stats.revlog.prefix(50), id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(ratingName(entry.rating))
                                            .amgiFont(.bodyEmphasis)
                                        Spacer()
                                        Text(reviewDate(entry.id))
                                            .amgiFont(.caption)
                                            .foregroundStyle(palette.textSecondary)
                                    }
                                    Text(historyDetail(entry))
                                        .amgiFont(.caption)
                                        .foregroundStyle(palette.textSecondary)
                                        .monospacedDigit()
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } else if statsFailed {
                    Section("Review History") {
                        Text("Couldn't load review history.")
                            .amgiFont(.body)
                            .foregroundStyle(palette.textSecondary)
                    }
                } else {
                    Section("Review History") {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading history…")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            } else {
                Text("Scheduling info is per-card. Switch to Cards mode or pick a specific card to inspect it.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .task(id: card?.id) {
            await loadStats()
        }
    }

    private func loadStats() async {
        stats = nil
        statsFailed = false
        guard let card else { return }
        do {
            stats = try await cards.cardStats(card.id)
        } catch {
            statsFailed = true
        }
    }

    private func ratingName(_ rating: Int32) -> String {
        switch rating {
        case 1: "Again"
        case 2: "Hard"
        case 3: "Good"
        case 4: "Easy"
        case 0: "Manual"
        default: "Rated \(rating)"
        }
    }

    private func reviewDate(_ millisOrSecs: Int64) -> String {
        // Revlog ids are millisecond timestamps.
        let secs: TimeInterval = millisOrSecs > 1_000_000_000_000
            ? TimeInterval(millisOrSecs) / 1000
            : TimeInterval(millisOrSecs)
        let date = Date(timeIntervalSince1970: secs)
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func historyDetail(_ entry: RevlogEntry) -> String {
        var parts: [String] = []
        if entry.intervalSecs > 0 {
            parts.append("interval \(formatSecs(entry.intervalSecs))")
        }
        if entry.easeFactor > 0 {
            parts.append("ease \(entry.easeFactor)‰")
        }
        if entry.takenSecs > 0 {
            parts.append("took \(entry.takenSecs)s")
        }
        return parts.joined(separator: " · ")
    }

    private func formatSecs(_ secs: Int64) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
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
        // Scheduler-aware: new = position, learning = timestamp,
        // review = day index. Never the old coarse due/86400 arithmetic.
        if card.queue == -1 || card.queue < -1 { return "—" }
        switch card.type {
        case 0: return "#\(card.due)"
        case 1, 3:
            let date = Date(timeIntervalSince1970: TimeInterval(card.due))
            let cal = Calendar.current
            if cal.isDateInToday(date) { return "Today" }
            if cal.isDateInTomorrow(date) { return "Tomorrow" }
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        default:
            return card.due <= 0 ? "Today" : "In \(card.due)d"
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
    /// Increment to force a reload (audio replay). Read in `updateUIView`
    /// via the struct's identity so SwiftUI re-issues the load.
    var replayToken = 0

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
    /// Increment to force a reload (audio replay).
    var replayToken = 0

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

