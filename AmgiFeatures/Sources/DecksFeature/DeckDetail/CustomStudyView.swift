import SwiftUI
import AmgiAppCore
import AmgiTheme
import AnkiClients
import AnkiKit
import Dependencies

struct CustomStudyView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case newLimit = "Increase new limit"
        case reviewLimit = "Increase review limit"
        case forgotten = "Review forgotten cards"
        case ahead = "Review ahead"
        case preview = "Preview new cards"
        case stateAndTag = "Study by state or tag"

        var id: Self { self }
        var localizedTitle: String { L10n.key(rawValue) }
        var createsSession: Bool {
            switch self {
            case .newLimit, .reviewLimit: false
            default: true
            }
        }
    }

    private enum Phase {
        case settings
        case ready(DeckInfo)
    }

    private enum TagChoice: String, CaseIterable {
        case any = "Any"
        case include = "Include"
        case exclude = "Exclude"

        var localizedTitle: String { L10n.key(rawValue) }
    }

    let deck: DeckInfo
    let onChanges: (CollectionChanges) -> Void
    let onOpenSession: (DeckInfo) -> Void
    let onStudySession: (DeckInfo) -> Void

    @Dependency(\.deckClient) private var deckClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.palette) private var palette

    @State private var phase: Phase = .settings
    @State private var mode: Mode = .forgotten
    @State private var amounts: [Mode: Int] = [
        .newLimit: 10,
        .reviewLimit: 50,
        .forgotten: 1,
        .ahead: 7,
        .preview: 1,
    ]
    @State private var cardState: CustomStudyCardState = .all
    @State private var cardLimit = 100
    @State private var tags: [CustomStudyTag] = []
    @State private var defaults: CustomStudyDefaults?
    @State private var tagChoices: [String: TagChoice] = [:]
    @State private var existingSession = false
    @State private var showReplacementConfirmation = false
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .settings:
                    settingsBody
                case .ready(let session):
                    readyBody(session)
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if case .settings = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(primaryActionTitle) { beginSubmit() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isLoading || isSubmitting)
                    }
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 820, minHeight: 520, idealHeight: 620)
        .task { await loadDefaults() }
        .confirmationDialog(
            "Replace the current Custom Study Session?",
            isPresented: $showReplacementConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Session") { Task { await submit() } }
            Button("Keep Current", role: .cancel) {}
        } message: {
            Text("Its cards will return to their original decks before this selection is built. No cards will be deleted.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Done", isPresented: Binding(
            get: { completionMessage != nil },
            set: { if !$0 { completionMessage = nil } }
        )) {
            Button("OK") { dismiss() }
        } message: {
            Text(completionMessage ?? "")
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
    }

    private var navigationTitle: String {
        switch phase {
        case .settings: L10n.text("Custom Study")
        case .ready: L10n.text("Session Ready")
        }
    }

    @ViewBuilder
    private var settingsBody: some View {
        if isLoading {
            ProgressView("Loading options…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.background)
        } else if horizontalSizeClass == .compact {
            mobileSettings
        } else {
            regularSettings
        }
    }

    private var regularSettings: some View {
        HStack(spacing: 0) {
            List(selection: Binding<Mode?>(
                get: { mode },
                set: { if let selectedMode = $0 { mode = selectedMode } }
            )) {
                ForEach(Mode.allCases) { item in
                    Text(item.localizedTitle).tag(item)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 258)

            Divider()

            ScrollView {
                settingsForm
                    .padding(28)
            }
        }
    }

    private var mobileSettings: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deck.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("Includes subdecks")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("STUDY MODE")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                        Menu {
                            Picker("Study mode", selection: $mode) {
                                ForEach(Mode.allCases) { Text($0.localizedTitle).tag($0) }
                            }
                        } label: {
                            HStack {
                                Text(mode.localizedTitle)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
                        }
                        Text(modeDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let availabilityText {
                        Text(availabilityText)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }

                    if mode == .stateAndTag {
                        cardStateAndTags
                    } else {
                        compactAmountControl
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(consequenceTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text(consequenceDetail)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
        .background(palette.background)
    }

    private var compactAmountControl: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fieldLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Text(amountText)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            HStack(spacing: 0) {
                amountButton(systemImage: "minus", delta: -1)
                Divider().frame(height: 24)
                amountButton(systemImage: "plus", delta: 1)
            }
            .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.control)
                    .strokeBorder(palette.separator, lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
    }

    private func amountButton(systemImage: String, delta: Int) -> some View {
        Button {
            amounts[mode] = min(max(amount + delta, amountRange.lowerBound), amountRange.upperBound)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .disabled(delta < 0 && amount == amountRange.lowerBound)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("\(deck.name) · \(L10n.text("Includes subdecks"))")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.localizedTitle)
                    .amgiFont(.sectionHeading)
                Text(modeDescription)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }

            if let availabilityText {
                Text(availabilityText)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            if mode == .stateAndTag {
                cardStateAndTags
            } else {
                Stepper(value: amountBinding, in: amountRange) {
                    LabeledContent(fieldLabel, value: amountText)
                }
                .padding(16)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(consequenceTitle)
                    .amgiFont(.bodyEmphasis)
                Text(consequenceDetail)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var cardStateAndTags: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Card state", selection: $cardState) {
                Text("New").tag(CustomStudyCardState.new)
                Text("Due").tag(CustomStudyCardState.due)
                Text("Review").tag(CustomStudyCardState.review)
                Text("All cards").tag(CustomStudyCardState.all)
            }
            Stepper("Up to \(cardLimit) cards", value: $cardLimit, in: 1...99_999)

            if !tags.isEmpty {
                Divider()
                Text("Tags").amgiFont(.bodyEmphasis)
                Text("Included tags match any selection. Cards matching any excluded tag are removed.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                ForEach(tags) { tag in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tag.name).amgiFont(.captionBold)
                        Picker(tag.name, selection: tagBinding(tag.name)) {
                            ForEach(TagChoice.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
    }

    private func readyBody(_ session: DeckInfo) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 38))
                .foregroundStyle(palette.accent)
            Text("Custom Study Session is ready")
                .amgiFont(.sectionHeading)
            Text(L10n.format("Built from %@ and its subdecks. The session is a standard Anki filtered deck.", [deck.name]))
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            HStack {
                countPill(L10n.text("New"), session.counts.newCount, palette.cardStateNew)
                countPill(L10n.text("Learning"), session.counts.learnCount, palette.cardStateLearning)
                countPill(L10n.text("Review"), session.counts.reviewCount, palette.cardStateReview)
            }
            .padding(.vertical, 8)
            Button("Study Now") { onStudySession(session) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Open Session") { onOpenSession(session) }
            Button("Edit Settings") { phase = .settings }
        }
        .padding(32)
        .frame(maxWidth: 560, maxHeight: .infinity)
    }

    private func countPill(_ title: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).amgiFont(.caption).foregroundStyle(palette.textSecondary)
            Text(count.formatted()).amgiFont(.sectionHeading).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
    }

    private func loadDefaults() async {
        do {
            async let defaults = deckClient.customStudyDefaults(deck.id)
            async let decks = deckClient.fetchAll()
            let (loaded, allDecks) = try await (defaults, decks)
            self.defaults = loaded
            tags = loaded.tags
            amounts[.newLimit] = max(1, Int(loaded.extendNew))
            amounts[.reviewLimit] = max(1, Int(loaded.extendReview))
            tagChoices = Dictionary(uniqueKeysWithValues: loaded.tags.map {
                ($0.name, $0.isIncluded ? .include : ($0.isExcluded ? .exclude : .any))
            })
            existingSession = allDecks.contains {
                $0.name == "Custom Study Session" && $0.isFiltered
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func beginSubmit() {
        if mode.createsSession, existingSession {
            showReplacementConfirmation = true
        } else {
            Task { await submit() }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await deckClient.customStudy(deck.id, makeRequest())
            onChanges(result.changes)
            if let session = result.sessionDeck {
                existingSession = true
                phase = .ready(session)
            } else {
                completionMessage = mode == .newLimit
                    ? L10n.format("Today's new-card limit increased by %lld.", [amount])
                    : L10n.format("Today's review limit increased by %lld.", [amount])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeRequest() -> CustomStudyRequest {
        switch mode {
        case .newLimit: .increaseNewLimit(Int32(amount))
        case .reviewLimit: .increaseReviewLimit(Int32(amount))
        case .forgotten: .reviewForgotten(days: UInt32(amount))
        case .ahead: .reviewAhead(days: UInt32(amount))
        case .preview: .previewNew(days: UInt32(amount))
        case .stateAndTag:
            .studyByState(
                cardState,
                limit: UInt32(cardLimit),
                includeTags: tagChoices.compactMap { $0.value == .include ? $0.key : nil },
                excludeTags: tagChoices.compactMap { $0.value == .exclude ? $0.key : nil }
            )
        }
    }

    private func tagBinding(_ name: String) -> Binding<TagChoice> {
        Binding(
            get: { tagChoices[name, default: .any] },
            set: { tagChoices[name] = $0 }
        )
    }

    private var amount: Int { amounts[mode, default: 1] }
    private var amountBinding: Binding<Int> {
        Binding(
            get: { amount },
            set: { amounts[mode] = $0 }
        )
    }

    private var amountRange: ClosedRange<Int> { mode == .forgotten ? 1...30 : 1...99_999 }
    private var fieldLabel: String {
        switch mode {
        case .newLimit: L10n.text("Extra new cards")
        case .reviewLimit: L10n.text("Extra review cards")
        case .forgotten: L10n.text("Forgotten in the last")
        case .ahead: L10n.text("Review ahead by")
        case .preview: L10n.text("Added in the last")
        case .stateAndTag: ""
        }
    }
    private var amountText: String {
        switch mode {
        case .newLimit, .reviewLimit:
            L10n.format("%lld cards", [amount])
        default:
            amount == 1 ? L10n.text("1 day") : L10n.format("%lld days", [amount])
        }
    }
    private var primaryActionTitle: String {
        mode.createsSession ? L10n.text("Create Session") : L10n.text("Increase Limit")
    }
    private var availabilityText: String? {
        guard let defaults else { return nil }
        switch mode {
        case .newLimit:
            return L10n.format(
                "Available: %lld here · %lld in subdecks",
                [defaults.availableNew, defaults.availableNewInChildren]
            )
        case .reviewLimit:
            return L10n.format(
                "Available: %lld here · %lld in subdecks",
                [defaults.availableReview, defaults.availableReviewInChildren]
            )
        default:
            return nil
        }
    }
    private var modeDescription: String {
        switch mode {
        case .newLimit: L10n.text("Study more new cards today without changing your deck preset.")
        case .reviewLimit: L10n.text("Show more cards that are already due for review today.")
        case .forgotten: L10n.text("Revisit cards you answered Again to strengthen difficult material.")
        case .ahead: L10n.text("Study upcoming reviews before a trip or a busy week.")
        case .preview: L10n.text("Preview recently added new cards without rescheduling them.")
        case .stateAndTag: L10n.text("Build a focused session by card state, limit, and tags.")
        }
    }
    private var consequenceTitle: String {
        switch mode {
        case .newLimit, .reviewLimit: L10n.text("For today only")
        case .forgotten, .preview: L10n.text("Your schedule stays unchanged")
        case .ahead: L10n.text("Answers update scheduling")
        case .stateAndTag: cardState == .all
                ? L10n.text("Your schedule stays unchanged")
                : L10n.text("Answers update scheduling")
        }
    }
    private var consequenceDetail: String {
        switch mode {
        case .newLimit: L10n.text("The daily limit returns to normal tomorrow. Cards remain in this deck.")
        case .reviewLimit: L10n.text("This raises today's limit; it does not bring future reviews forward.")
        case .forgotten, .preview: L10n.text("Cards stay linked to their original decks. Empty the session to return them.")
        case .ahead: L10n.text("Cards receive new due dates based on your answers and how early you review them.")
        case .stateAndTag:
            cardState == .all
                ? L10n.text("All-card sessions are previews and do not reschedule cards.")
                : L10n.text("Answers update scheduling. Empty the session to return remaining cards.")
        }
    }
}
