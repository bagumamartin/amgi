import SwiftUI
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
        Group {
            if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
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

    private var regularBody: some View {
        NavigationStack {
            Group {
                switch phase {
                case .settings:
                    settingsBody
                case .ready(let session):
                    readyBody(session)
                }
            }
            .navigationTitle("Custom Study")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var compactBody: some View {
        switch phase {
        case .settings:
            if isLoading {
                ProgressView("Loading options…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
            } else {
                mobileSettings
            }
        case .ready(let session):
            VStack(spacing: 0) {
                compactHeader(title: "Session Ready")
                readyBody(session)
            }
            .background(palette.background)
        }
    }

    @ViewBuilder
    private var settingsBody: some View {
        if isLoading {
            ProgressView("Loading options…")
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
                    Text(item.rawValue).tag(item)
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
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var mobileSettings: some View {
        VStack(spacing: 0) {
            compactHeader(title: "Custom Study")
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
                                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text(modeDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let availabilityText {
                        Text(availabilityText)
                            .font(.footnote)
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
                .padding(.bottom, 20)
            }
            mobileActionBar
        }
        .background(palette.background)
    }

    private func compactHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(palette.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var compactAmountControl: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fieldLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Text("\(amount) \(fieldUnit)")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            HStack(spacing: 0) {
                amountButton(systemImage: "minus", delta: -1)
                Divider().frame(height: 24)
                amountButton(systemImage: "plus", delta: 1)
            }
            .background(palette.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(palette.separator, lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
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

    private var mobileActionBar: some View {
        VStack(spacing: 6) {
            Button(primaryActionTitle) { beginSubmit() }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 12))
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            Button("Cancel") { dismiss() }
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("\(deck.name) · Includes subdecks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.rawValue)
                    .font(.title3.weight(.semibold))
                Text(modeDescription)
                    .foregroundStyle(.secondary)
            }

            if let availabilityText {
                Text(availabilityText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if mode == .stateAndTag {
                cardStateAndTags
            } else {
                Stepper(value: amountBinding, in: amountRange) {
                    LabeledContent(fieldLabel, value: "\(amount) \(fieldUnit)")
                }
                .padding(16)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(consequenceTitle)
                    .font(.headline)
                Text(consequenceDetail)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
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
                Text("Tags").font(.headline)
                Text("Included tags match any selection. Cards matching any excluded tag are removed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(tags) { tag in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tag.name).font(.subheadline)
                        Picker(tag.name, selection: tagBinding(tag.name)) {
                            ForEach(TagChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button(primaryActionTitle) { beginSubmit() }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
        }
        .padding()
        .background(.bar)
    }

    private func readyBody(_ session: DeckInfo) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
            Text("Custom Study Session is ready")
                .font(.title2.weight(.bold))
            Text("Built from \(deck.name) and its subdecks. The session is a standard Anki filtered deck.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                countPill("New", session.counts.newCount, .blue)
                countPill("Learning", session.counts.learnCount, .orange)
                countPill("Review", session.counts.reviewCount, .green)
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(count.formatted()).font(.title2.weight(.semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
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
                    ? "Today's new-card limit increased by \(amount)."
                    : "Today's review limit increased by \(amount)."
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
        case .newLimit: "Extra new cards"
        case .reviewLimit: "Extra review cards"
        case .forgotten: "Forgotten in the last"
        case .ahead: "Review ahead by"
        case .preview: "Added in the last"
        case .stateAndTag: ""
        }
    }
    private var fieldUnit: String {
        switch mode {
        case .newLimit, .reviewLimit: "cards"
        default: amount == 1 ? "day" : "days"
        }
    }
    private var primaryActionTitle: String { mode.createsSession ? "Create Session" : "Increase Limit" }
    private var availabilityText: String? {
        guard let defaults else { return nil }
        switch mode {
        case .newLimit:
            return "Available: \(defaults.availableNew) here · \(defaults.availableNewInChildren) in subdecks"
        case .reviewLimit:
            return "Available: \(defaults.availableReview) here · \(defaults.availableReviewInChildren) in subdecks"
        default:
            return nil
        }
    }
    private var modeDescription: String {
        switch mode {
        case .newLimit: "Study more new cards today without changing your deck preset."
        case .reviewLimit: "Show more cards that are already due for review today."
        case .forgotten: "Revisit cards you answered Again to strengthen difficult material."
        case .ahead: "Study upcoming reviews before a trip or a busy week."
        case .preview: "Preview recently added new cards without rescheduling them."
        case .stateAndTag: "Build a focused session by card state, limit, and tags."
        }
    }
    private var consequenceTitle: String {
        switch mode {
        case .newLimit, .reviewLimit: "For today only"
        case .forgotten, .preview: "Your schedule stays unchanged"
        case .ahead: "Answers update scheduling"
        case .stateAndTag: cardState == .all ? "Your schedule stays unchanged" : "Answers update scheduling"
        }
    }
    private var consequenceDetail: String {
        switch mode {
        case .newLimit: "The daily limit returns to normal tomorrow. Cards remain in this deck."
        case .reviewLimit: "This raises today's limit; it does not bring future reviews forward."
        case .forgotten, .preview: "Cards stay linked to their original decks. Empty the session to return them."
        case .ahead: "Cards receive new due dates based on your answers and how early you review them."
        case .stateAndTag:
            cardState == .all
                ? "All-card sessions are previews and do not reschedule cards."
                : "Answers update scheduling. Empty the session to return remaining cards."
        }
    }
}
