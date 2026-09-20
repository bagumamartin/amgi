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
#elseif canImport(AppKit)
import AppKit
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
    /// Clears the inspector selection (split Close control).
    var onClose: (() -> Void)?
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
    /// Bumped after a successful edit so Preview re-renders the same card.
    @State private var previewEpoch = 0

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
        .amgiScreenCanvas()
        .navigationTitle(tab == .edit ? "" : "Details")
        .toolbar { detailChrome }
        #if os(iOS)
        .toolbarRole(tab == .edit ? .automatic : .editor)
        #endif
    }

    @ToolbarContentBuilder
    private var detailChrome: some ToolbarContent {
        if tab == .edit {
            detailsPrincipalItem
        }
        if tab != .edit, onClose != nil {
            closeToolbarItem
        }
    }

    @ToolbarContentBuilder
    private var detailsPrincipalItem: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                Text("Details")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                Text("Details")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
            }
        }
        #else
        ToolbarItem(placement: .principal) {
            Text("Details")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
        }
        #endif
    }

    @ToolbarContentBuilder
    private var closeToolbarItem: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                closeButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                closeButton
            }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            closeButton
        }
        #endif
    }

    private var closeButton: some View {
        Button {
            onClose?()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(palette.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close details")
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
                NoteEditorView(
                    note: note,
                    deckID: deckID,
                    principalTitle: "Details",
                    onCancel: { tab = .preview },
                    onClose: onClose,
                    onSave: {
                        onSaved()
                        previewEpoch += 1
                        tab = .preview
                    }
                )
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
                    cardOrdinal: infoCard?.ord ?? 0,
                    reloadToken: previewEpoch,
                    backSideOnly: $backSideOnly,
                    nav: previewNav,
                    markIndicator: markState,
                    flagValue: infoCard.map { $0.flags & 0b111 }
                )
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
    @Environment(\.colorScheme) private var colorScheme
    let cardId: CardID?
    var cardOrdinal: Int32 = 0
    var reloadToken = 0
    /// Always show the answer field, skipping the question side.
    @Binding var backSideOnly: Bool
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
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        previewHeader
                        flipCard(rendered)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    previewControls
                }
            } else if failed {
                emptyState("Preview unavailable for this row.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(cardId?.rawValue ?? 0)-\(reloadToken)") {
            showAnswer = backSideOnly
            await load()
        }
        .onChange(of: backSideOnly) { _, new in
            showAnswer = new
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 12) {
            if let nav {
                previewNavButton(
                    title: "Previous",
                    systemImage: "chevron.left",
                    enabled: nav.canPrev
                ) {
                    Task { await step(nav, by: -1) }
                }

                Spacer(minLength: 8)
                VStack(spacing: 4) {
                    if let idx = nav.currentIndex {
                        Text("Card \(idx + 1) of \(nav.ids.count)")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                            .monospacedDigit()
                    }
                    indicatorRow
                }
                Spacer(minLength: 8)

                previewNavButton(
                    title: "Next",
                    systemImage: "chevron.right",
                    iconTrailing: true,
                    enabled: nav.canNext
                ) {
                    Task { await step(nav, by: 1) }
                }
            } else {
                Spacer()
                indicatorRow
                Spacer()
            }
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.top, AmgiSpacing.md)
        .padding(.bottom, AmgiSpacing.sm)
    }

    private func previewNavButton(
        title: String,
        systemImage: String,
        iconTrailing: Bool = false,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !iconTrailing {
                    Image(systemName: systemImage)
                }
                Text(title)
                if iconTrailing {
                    Image(systemName: systemImage)
                }
            }
            .amgiFont(.bodyEmphasis)
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressScale)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    private var previewControls: some View {
        HStack(spacing: 10) {
            if !backSideOnly {
                previewButton(
                    showAnswer ? "Show Question" : "Show Answer",
                    prominent: true
                ) {
                    withAnimation(AmgiMotion.quick) { showAnswer.toggle() }
                }
            }
            previewButton(backSideOnly ? "Question Only" : "Answer Only", prominent: backSideOnly) {
                withAnimation(AmgiMotion.quick) {
                    backSideOnly.toggle()
                    showAnswer = backSideOnly
                }
            }
            previewButton("Play Audio", prominent: false) {
                replayToken += 1
            }
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.bottom, AmgiSpacing.lg)
    }

    @ViewBuilder
    private func previewButton(
        _ title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = Text(title)
            .amgiFont(.bodyEmphasis)
            .foregroundStyle(prominent ? Color.white : palette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Capsule())
        if prominent {
            Button(action: action) { label }
                .buttonStyle(.pressScale)
                .background(palette.accent, in: Capsule())
        } else {
            Button(action: action) { label }
                .buttonStyle(.pressScale)
                .amgiMaterial(.regular, in: Capsule(), interactive: true)
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
            }
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
            html: BrowsePreviewHTML.displayHTML(
                front: rendered.frontHTML,
                back: rendered.backHTML,
                showAnswer: showAnswer,
                answerOnly: backSideOnly
            ),
            css: rendered.css,
            isDarkMode: colorScheme == .dark,
            cardOrdinal: cardOrdinal,
            replayToken: replayToken
        )
        .background(palette.background)
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

// MARK: - Info pane (native facts + review history + FSRS)

struct CardInfoPane: View {
    @Environment(\.palette) private var palette
    /// Cards-mode rows hand a full record; notes-mode hands nil (info is
    /// per-card — desktop shows note's first card).
    let card: CardRecord?

    @State private var stats: CardStatsInfo?
    @State private var statsFailed = false
    @State private var showsTechnicalDetails = true
    @Dependency(\.cardClient) private var cards

    var body: some View {
        ScrollView {
            if let card {
                VStack(alignment: .leading, spacing: 24) {
                    infoHeading("Study status", systemImage: "calendar.badge.clock", tint: palette.accent)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                        spacing: 12
                    ) {
                        metricCard(
                            "State",
                            queueStateName(card),
                            systemImage: "circle.fill",
                            tint: typeColor(card)
                        )
                        metricCard("Due", dueDescription(card), systemImage: "calendar", tint: dueColor(card))
                        metricCard(
                            "Reviews",
                            "\(card.reps)",
                            systemImage: "checkmark.circle.fill",
                            tint: palette.cardStateReview
                        )
                        metricCard(
                            "Lapses",
                            "\(card.lapses)",
                            systemImage: "arrow.counterclockwise",
                            tint: card.lapses > 0 ? palette.cardStateRelearn : palette.textTertiary
                        )
                        if card.ivl > 0 {
                            metricCard(
                                "Interval",
                                "\(card.ivl) days",
                                systemImage: "clock.fill",
                                tint: palette.info
                            )
                        }
                        if card.factor > 0 {
                            metricCard(
                                "Ease",
                                "\(card.factor / 10)%",
                                systemImage: "gauge.with.dots.needle.50percent",
                                tint: easeColor(card.factor)
                            )
                        }
                    }

                    if let stats, stats.stability != nil || stats.difficulty != nil || stats.retrievabilityPct != nil {
                        infoHeading("Memory", systemImage: "brain.head.profile", tint: palette.cardStateMature)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                            spacing: 12
                        ) {
                            if let value = stats.retrievabilityPct {
                                metricCard(
                                    "Recall chance",
                                    String(format: "%.0f%%", value),
                                    systemImage: "chart.line.uptrend.xyaxis",
                                    tint: recallColor(value)
                                )
                            }
                            if let value = stats.stability {
                                metricCard(
                                    "Stability",
                                    String(format: "%.1f days", value),
                                    systemImage: "waveform.path.ecg",
                                    tint: palette.info
                                )
                            }
                            if let value = stats.difficulty {
                                metricCard(
                                    "Difficulty",
                                    String(format: "%.0f%%", value * 100),
                                    systemImage: "speedometer",
                                    tint: difficultyColor(value)
                                )
                            }
                        }
                    }

                    infoHeading("Review history", systemImage: "clock.arrow.circlepath", tint: palette.cardStateLearning)
                    historyContent

                    technicalDetails(card)
                }
                .frame(maxWidth: 900)
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "No Card Selected",
                    systemImage: "rectangle.stack",
                    description: Text("Choose a card to see its study status and review history.")
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .task(id: card?.id) {
            await loadStats()
        }
    }

    private func infoHeading(_ title: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(title).amgiFont(.bodyEmphasis).foregroundStyle(palette.textPrimary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }

    private func metricCard(
        _ label: String,
        _ value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .amgiFont(.captionBold)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                Text(value.isEmpty ? "—" : value)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }

    @ViewBuilder
    private var historyContent: some View {
        if let stats {
            if stats.revlog.isEmpty {
                Text("No reviews yet. This card is ready for its first study session.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(stats.revlog.prefix(50).enumerated()), id: \.element.id) { _, entry in
                        let tint = ratingColor(entry.rating)
                        HStack(alignment: .top, spacing: 12) {
                            Text(ratingName(entry.rating))
                                .amgiFont(.captionBold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(tint, in: Capsule())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(historyDetail(entry))
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textPrimary)
                                Text(reviewDate(entry.id))
                                    .amgiFont(.micro)
                                    .foregroundStyle(palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
                    }
                }
            }
        } else if statsFailed {
            Text("Review history couldn’t be loaded.")
                .foregroundStyle(palette.textSecondary)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading review history…").foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func technicalDetails(_ card: CardRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(AmgiMotion.quick) { showsTechnicalDetails.toggle() }
            } label: {
                HStack {
                    Label {
                        Text("Technical details")
                            .amgiFont(.bodyEmphasis)
                            .foregroundStyle(palette.textPrimary)
                    } icon: {
                        Image(systemName: "number")
                            .foregroundStyle(palette.info)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(showsTechnicalDetails ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsTechnicalDetails {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                    spacing: 10
                ) {
                    idTile("Card", "\(card.id.rawValue)", tint: palette.accent)
                    idTile("Note", "\(card.nid.rawValue)", tint: palette.cardStateMature)
                    idTile("Deck", "\(card.did.rawValue)", tint: palette.info)
                    if card.odid != DeckID(0) {
                        idTile("Original deck", "\(card.odid.rawValue)", tint: palette.warning)
                    }
                    if (card.flags & 0b111) != 0 {
                        idTile("Flag", flagName(card.flags & 0b111), tint: flagColor(card.flags & 0b111))
                    }
                }
            }
        }
        .padding(16)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }

    private func idTile(_ label: String, _ value: String, tint: Color) -> some View {
        Button {
            copyToPasteboard(value)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased())
                    .amgiFont(.micro)
                    .foregroundStyle(tint)
                Text(value)
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
        }
        .buttonStyle(.pressScale)
        .help("Copy \(label) ID")
        .accessibilityLabel("\(label) \(value), copy")
    }

    private func copyToPasteboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
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

    private func typeName(_ type: Int16) -> String {
        switch type {
        case 0: "New"
        case 1: "Learning"
        case 2: "Review"
        case 3: "Relearning"
        default: "type \(type)"
        }
    }

    private func queueStateName(_ card: CardRecord) -> String {
        if card.queue < -1 { return "Buried" }
        if card.queue == -1 { return "Suspended" }
        return typeName(card.type)
    }

    private func typeColor(_ card: CardRecord) -> Color {
        if card.queue < -1 { return palette.warning }
        if card.queue == -1 { return palette.cardStateSuspended }
        switch card.type {
        case 0: return palette.cardStateNew
        case 1: return palette.cardStateLearning
        case 3: return palette.cardStateRelearn
        default: return palette.cardStateReview
        }
    }

    private func dueColor(_ card: CardRecord) -> Color {
        if card.queue == -1 || card.queue < -1 { return palette.cardStateSuspended }
        switch card.type {
        case 0: return palette.cardStateNew
        case 1, 3:
            let date = Date(timeIntervalSince1970: TimeInterval(card.due))
            return date <= Date() ? palette.warning : palette.info
        default:
            return card.due <= 0 ? palette.warning : palette.info
        }
    }

    private func easeColor(_ factor: Int32) -> Color {
        let percent = factor / 10
        if percent >= 250 { return palette.cardStateReview }
        if percent >= 200 { return palette.cardStateLearning }
        return palette.cardStateRelearn
    }

    private func recallColor(_ percent: Float) -> Color {
        if percent >= 80 { return palette.cardStateReview }
        if percent >= 50 { return palette.cardStateLearning }
        return palette.cardStateRelearn
    }

    private func difficultyColor(_ value: Float) -> Color {
        if value < 0.4 { return palette.cardStateReview }
        if value < 0.7 { return palette.cardStateLearning }
        return palette.cardStateRelearn
    }

    private func ratingColor(_ rating: Int32) -> Color {
        switch rating {
        case 1: return palette.cardStateRelearn
        case 2: return palette.cardStateLearning
        case 3: return palette.cardStateReview
        case 4: return palette.cardStateNew
        default: return palette.textTertiary
        }
    }

    private func flagColor(_ flag: Int32) -> Color {
        switch flag {
        case 1: return palette.danger
        case 2: return palette.warning
        case 3: return palette.positive
        case 4: return palette.accent
        case 5: return palette.cardStateRelearn
        case 6: return palette.info
        case 7: return palette.cardStateMature
        default: return palette.textTertiary
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
    var isDarkMode = false
    var cardOrdinal: Int32 = 0
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
        BrowsePreviewHTML.wrappedDocument(
            html: html,
            css: css,
            isDarkMode: isDarkMode,
            cardOrdinal: cardOrdinal
        )
    }
}
#elseif os(macOS)
private struct BrowseCardPreview: NSViewRepresentable {
    let html: String
    let css: String
    var isDarkMode = false
    var cardOrdinal: Int32 = 0
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
        BrowsePreviewHTML.wrappedDocument(
            html: html,
            css: css,
            isDarkMode: isDarkMode,
            cardOrdinal: cardOrdinal
        )
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
