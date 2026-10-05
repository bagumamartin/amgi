import SwiftUI
import AmgiUI
import AmgiTheme
import AnkiKit
import AnkiClients
import Dependencies
import Foundation

enum DeckConfigCategory: String, CaseIterable, Identifiable, Equatable {
    case preset
    case scheduling
    case reviewFlow
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preset: "Preset"
        case .scheduling: "Scheduling"
        case .reviewFlow: "Reviews & Timers"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .preset: "slider.horizontal.below.rectangle"
        case .scheduling: "calendar.badge.clock"
        case .reviewFlow: "timer"
        case .advanced: "gearshape.2"
        }
    }
}

enum DeckConfigLayout: Equatable {
    case compactForm
    case splitEditor

    static let categoryWidth: CGFloat = 160
    static let summaryWidth: CGFloat = 190
    static let settingsMinimumWidth: CGFloat = 340
    static let minimumWidth = categoryWidth + summaryWidth + settingsMinimumWidth

    static func resolve(isRegularWidth: Bool, availableWidth: CGFloat) -> Self {
        isRegularWidth && availableWidth >= minimumWidth ? .splitEditor : .compactForm
    }
}

/// Per-deck study options. The editable state and all load/save plumbing
/// live in `DeckConfigModel`; this Container binds each form section to
/// `$model.field` and translates engine outcomes into `destination`
/// transitions. Each form section lives in `DeckConfigSections.swift` so
/// SwiftUI can diff the section in isolation and `body` stays readable.
/// Modal presentation (alert + sheet) is driven by a single
/// `DeckConfigDestination?`, applied via the `DeckConfigPresentations`
/// modifier. See the Decks preview-decoupling spec.
struct DeckConfigView: View {
    let deckId: DeckID
    let deckName: String
    let onDismiss: () -> Void
    let onSaved: () -> Void

    @State private var model: DeckConfigModel
    @State private var selectedCategory: DeckConfigCategory = .preset

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(deckId: DeckID, deckName: String, initialCategory: DeckConfigCategory = .preset,
         requiredActivationID: UUID? = nil, onSaved: @escaping () -> Void = {}, onDismiss: @escaping () -> Void) {
        self.deckId = deckId
        self.deckName = deckName
        self.onDismiss = onDismiss
        self.onSaved = onSaved
        _selectedCategory = State(initialValue: initialCategory)
        _model = State(wrappedValue: DeckConfigModel(deckId: deckId, deckName: deckName,
            requiredActivationID: requiredActivationID))
    }

    var body: some View {
        formContent
            .navigationTitle("Deck Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .modifier(DeckConfigPresentations(
                destination: $model.destination,
                currentAlert: model.currentAlert,
                alertTitle: model.alertTitle,
                newPresetName: $model.newPresetName,
                renamePresetDraft: $model.renamePresetDraft,
                deletingPresetName: model.currentPresetName,
                fallbackPresetName: model.deleteFallbackPresetName,
                onCreate: { Task { await model.createPreset() } },
                onRename: { Task { await model.renamePreset() } },
                onDelete: { Task { await model.deletePreset() } },
                onDismissSheet: { model.destination = nil }
            ))
            .task { await model.loadConfig() }
            #if os(macOS)
            .onExitCommand {
                if model.destination == nil { onDismiss() }
            }
            #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.destination != nil)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { if await model.saveConfig() { onSaved(); onDismiss() } } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasLoadedConfig || model.isSaving || model.destination != nil)
        }
    }

    @ViewBuilder
    private var formContent: some View {
        GeometryReader { proxy in
            let layout = DeckConfigLayout.resolve(
                isRegularWidth: usesRegularWidth,
                availableWidth: proxy.size.width
            )
            switch layout {
            case .compactForm:
                compactForm
            case .splitEditor:
                splitEditor
            }
        }
    }

    private var usesRegularWidth: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    /// iOS `List(selection:)` exposes optional selection bindings. Keep the
    /// editor state nonoptional so the section switch always has a value, but
    /// adapt it at the platform boundary and ignore a transient nil selection.
    private var categorySelection: Binding<DeckConfigCategory?> {
        Binding(
            get: { selectedCategory },
            set: { newSelection in
                if let newSelection {
                    selectedCategory = newSelection
                }
            }
        )
    }

    private var compactForm: some View {
        Form {
            loadStateSections
        }
    }

    @ViewBuilder
    private var loadStateSections: some View {
        if model.isLoading {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if let loadError = model.loadError {
            Section {
                Text(loadError).foregroundStyle(palette.danger)
                Button("Retry") { Task { await model.loadConfig() } }
            }
        } else {
            presetSection
            dailyLimitsSection
            newCardsSection
            lapsesSection
            orderSection
            burySection
            timerSection
            autoAdvanceSection
            advancedSection
            fsrsSection
            easyDaysSection
            applySection
        }
    }

    private var splitEditor: some View {
        HStack(spacing: 0) {
            List(DeckConfigCategory.allCases, selection: categorySelection) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
                    .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .frame(width: DeckConfigLayout.categoryWidth)
            .accessibilityLabel("Deck option categories")

            Divider()

            Form {
                if model.hasLoadedConfig {
                    selectedCategorySections
                } else {
                    loadStateSections
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(selectedCategory.title) settings")

            Divider()

            DeckConfigSummaryView(
                deckName: deckName,
                presetName: model.currentPresetName ?? "—",
                presetUseCount: model.presetUseCount,
                newCardsPerDay: model.newCardsPerDay,
                reviewsPerDay: model.reviewsPerDay,
                fsrsEnabled: model.fsrsEnabled,
                applyToChildren: model.applyToChildren,
                isSaving: model.isSaving
            )
            .frame(width: DeckConfigLayout.summaryWidth)
        }
    }

    @ViewBuilder
    private var selectedCategorySections: some View {
        if !model.hasLoadedConfig {
            EmptyView()
        } else {
            switch selectedCategory {
            case .preset:
                presetSection
            case .scheduling:
                dailyLimitsSection
                newCardsSection
                lapsesSection
                orderSection
                burySection
            case .reviewFlow:
                timerSection
                autoAdvanceSection
            case .advanced:
                advancedSection
                fsrsSection
                easyDaysSection
                applySection
            }
        }
    }

    private var presetSection: some View {
        PresetSection(
            presetOptions: model.presetOptions,
            selectedPresetID: model.selectedPresetID,
            selectedPresetName: model.currentPresetName ?? "—",
            presetUseCount: model.presetUseCount,
            canDeletePreset: model.canDeletePreset,
            isPresetMutating: model.isPresetMutating,
            hasLoadedConfig: model.hasLoadedConfig,
            onSelect: { target in Task { await model.selectPreset(target) } },
            onAdd: {
                model.newPresetName = ""
                model.destination = .alert(.createPreset)
            },
            onRename: {
                model.renamePresetDraft = model.currentPresetName ?? ""
                model.destination = .alert(.renamePreset)
            },
            onDelete: { model.destination = .alert(.deletePresetConfirm) }
        )
    }

    private var dailyLimitsSection: some View {
        DailyLimitsSection(
            newCardsPerDay: $model.newCardsPerDay,
            reviewsPerDay: $model.reviewsPerDay,
            newCardsIgnoreReviewLimit: $model.newCardsIgnoreReviewLimit,
            applyAllParentLimits: $model.applyAllParentLimits
        )
    }

    private var newCardsSection: some View {
        NewCardsSection(
            learningStepsText: $model.learningStepsText,
            graduatingGoodDays: $model.graduatingGoodDays,
            graduatingEasyDays: $model.graduatingEasyDays
        )
    }

    private var lapsesSection: some View {
        LapsesSection(
            relearningStepsText: $model.relearningStepsText,
            leechThreshold: $model.leechThreshold,
            leechAction: $model.leechAction
        )
    }

    private var orderSection: some View {
        OrderSection(
            newCardInsertOrder: $model.newCardInsertOrder,
            newCardGatherPriority: $model.newCardGatherPriority,
            newCardSortOrder: $model.newCardSortOrder,
            newMix: $model.newMix,
            reviewOrder: $model.reviewOrder,
            interdayLearningMix: $model.interdayLearningMix
        )
    }

    private var burySection: some View {
        BurySection(
            buryNew: $model.buryNew,
            buryReviews: $model.buryReviews,
            buryInterdayLearning: $model.buryInterdayLearning
        )
    }

    private var timerSection: some View {
        TimerSection(
            showTimer: $model.showTimer,
            capAnswerTimeToSecs: $model.capAnswerTimeToSecs,
            stopTimerOnAnswer: $model.stopTimerOnAnswer
        )
    }

    private var autoAdvanceSection: some View {
        AutoAdvanceSection(
            secondsToShowQuestion: $model.secondsToShowQuestion,
            secondsToShowAnswer: $model.secondsToShowAnswer,
            questionAction: $model.questionAction,
            answerAction: $model.answerAction
        )
    }

    private var advancedSection: some View {
        AdvancedSection(
            maximumReviewIntervalDays: $model.maximumReviewIntervalDays,
            intervalMultiplierPercent: $model.intervalMultiplierPercent,
            hardMultiplierPercent: $model.hardMultiplierPercent,
            easyMultiplierPercent: $model.easyMultiplierPercent,
            disableAutoplay: $model.disableAutoplay,
            waitForAudio: $model.waitForAudio
        )
    }

    private var fsrsSection: some View {
        FsrsSection(
            fsrsEnabled: $model.fsrsEnabled,
            desiredRetentionPercent: $model.desiredRetentionPercent,
            historicalRetentionPercent: $model.historicalRetentionPercent,
            fsrsHealthCheck: $model.fsrsHealthCheck,
            fsrsWeightsText: $model.fsrsWeightsText,
            isOptimizingFsrs: model.isOptimizingFsrs,
            onOptimizeCurrent: { Task { await model.optimizeCurrentPreset() } },
            onOpenSimulatorReview: { model.openSimulator(mode: .review) },
            onOpenSimulatorWorkload: { model.openSimulator(mode: .workload) },
            onOptimizeAll: { Task { await model.optimizeAllPresets() } }
        )
    }

    private var easyDaysSection: some View {
        EasyDaysSection(
            fsrsEnabled: model.fsrsEnabled,
            easyDayPercentages: $model.easyDayPercentages
        )
    }

    private var applySection: some View {
        ApplySection(applyToChildren: $model.applyToChildren)
    }
}

private struct DeckConfigSummaryView: View {
    let deckName: String
    let presetName: String
    let presetUseCount: Int
    let newCardsPerDay: Int32
    let reviewsPerDay: Int32
    let fsrsEnabled: Bool
    let applyToChildren: Bool
    let isSaving: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.md) {
            Text("Summary")
                .amgiFont(.sectionHeading)

            summaryRow("Deck", value: deckName)
            Divider()
            summaryRow("Preset", value: presetName)
            summaryRow("Used by", value: "\(presetUseCount) deck\(presetUseCount == 1 ? "" : "s")")
            Divider()
            summaryRow("New cards", value: "\(newCardsPerDay)/day")
            summaryRow("Reviews", value: "\(reviewsPerDay)/day")
            summaryRow("FSRS", value: fsrsEnabled ? "Enabled" : "Disabled")
            summaryRow("Subdecks", value: applyToChildren ? "Included" : "Not included")

            Spacer(minLength: 0)

            if isSaving {
                HStack(spacing: AmgiSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
                .foregroundStyle(palette.textSecondary)
            } else {
                Text("Return saves · Escape cancels")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(AmgiSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surfaceElevated)
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
            Text(value)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let _ = prepareDependencies {
        let config = DeckConfig(
            id: DeckConfigID(1),
            name: "Default",
            config: .init(
                learnSteps: [1, 10],
                relearnSteps: [10],
                newPerDay: 20,
                reviewsPerDay: 200,
                graduatingIntervalGood: 1,
                graduatingIntervalEasy: 4,
                leechThreshold: 8,
                desiredRetention: 0.9,
                historicalRetention: 0.9
            )
        )
        $0.deckClient.getDeckConfig = { _ in config }
        $0.deckClient.fetchDeckConfigContext = { _ in
            DeckConfigsForUpdate(
                allConfig: [DeckConfigsForUpdate.ConfigWithExtra(config: config, useCount: 12)],
                currentDeck: DeckConfigsForUpdate.CurrentDeck(name: "Japanese", configID: config.id),
                defaults: config
            )
        }
    }
    return NavigationStack {
        DeckConfigView(deckId: DeckID(1), deckName: "Japanese", onDismiss: {})
    }
}
#endif
