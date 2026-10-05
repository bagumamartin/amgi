import AmgiAppCore
import AmgiAppShared
import AnkiClients
import AnkiBackend
import AnkiKit
import Dependencies
import Foundation
import os



/// Owns the per-deck study-options editing surface: the `deckClient`
/// dependency, the loaded config + context, every editable form field, and
/// all load/save/preset/FSRS I/O. The `DeckConfigView` Container binds its
/// sections to `$model.field` and translates engine outcomes into
/// `destination` transitions, so the view itself carries no `@Dependency`.
@Observable
@MainActor
final class DeckConfigModel {
    let deckId: DeckID
    let deckName: String
    private let collectionActivationID: UUID?
    @ObservationIgnored @Dependency(\.ankiBackend) private var configBackend

    // Internal rather than private: the preset/FSRS methods live in
    // DeckConfigModel+Presets.swift now, and `private` is file-scoped.
    @ObservationIgnored @Dependency(\.deckClient) var deckClient
    @ObservationIgnored @Dependency(\.collectionStore) var collectionStore

    var loaded: LoadedConfig?
    var isLoading = true
    var isSaving = false
    var loadError: String?
    var destination: DeckConfigDestination?

    var newCardsPerDay: Int32 = 20
    var reviewsPerDay: Int32 = 200
    var newCardsIgnoreReviewLimit = false
    var applyAllParentLimits = false

    /// Step syntax is `m` / `h` / `d` in *data*, not copy — see
    /// `StudyDeckNaming` for the same reasoning applied to deck names. The
    /// numbers inside are read in the user's locale, but the unit letters stay
    /// ASCII so a schedule typed on one device reads the same on another.
    var learningStepsText: String = "1m 10m"
    var graduatingGoodDays: Int32 = 1
    var graduatingEasyDays: Int32 = 4

    var relearningStepsText: String = "10m"
    var leechThreshold: Int32 = 8
    var leechAction: LeechAction = .suspend

    /// Non-nil when the last `parseSteps` saw a token it could not read.
    /// `parseSteps` is also called from the preset and step-count paths, so
    /// the save path clears it before its own parse rather than trusting
    /// whatever ran last.
    var stepsParseError: String?

    var fsrsEnabled = false
    var desiredRetentionPercent: Double = 90
    var historicalRetentionPercent: Double = 90
    var fsrsHealthCheck = false
    var fsrsWeightsText: String = ""
    var fsrsParamSearch: String = ""
    var isOptimizingFsrs = false

    var applyToChildren = false

    // Preset CRUD — text-field draft state for the create/rename alerts.
    // (Presentation state itself lives in `destination`.)
    var isPresetMutating = false
    var newPresetName = ""
    var renamePresetDraft = ""

    // Bury
    var buryNew = true
    var buryReviews = true
    var buryInterdayLearning = false

    // Order
    var newCardInsertOrder: NewCardInsertOrder = .due
    var newCardGatherPriority: NewCardGatherPriority = .deck
    var newCardSortOrder: NewCardSortOrder = .template
    var newMix: ReviewMix = .mixWithReviews
    var reviewOrder: ReviewCardOrder = .day
    var interdayLearningMix: ReviewMix = .mixWithReviews

    // Timer
    var showTimer = false
    var capAnswerTimeToSecs: Int32 = 60
    var stopTimerOnAnswer = true

    // Auto-Advance
    var secondsToShowQuestion: Double = 0
    var secondsToShowAnswer: Double = 0
    var questionAction: QuestionAction = .showAnswer
    var answerAction: AnswerAction = .buryCard

    // Advanced
    var maximumReviewIntervalDays: Int32 = 36500
    var intervalMultiplierPercent: Double = 100
    var hardMultiplierPercent: Double = 120
    var easyMultiplierPercent: Double = 130
    var disableAutoplay = false
    var waitForAudio = false

    // Easy Days — per-weekday FSRS workload multipliers (Mon..Sun, 50..150%).
    var easyDayPercentages: [Double] = Array(repeating: 100, count: 7)

    struct LoadedConfig {
        var config: DeckConfig
        var context: DeckConfigsForUpdate
    }

    /// Settings opened by a decision must not save into a different profile
    /// after an await. The task-local reaches the backend's locked RPC gate.
    func collectionAccess<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await AnkiBackend.$requiredCollectionActivationID.withValue(collectionActivationID) {
                try await operation()
            }
        } catch {
            if let collectionActivationID, configBackend.collectionActivationID != collectionActivationID {
                throw DeckDecisionFailure(message: L10n.text("The active profile changed. Try again in the current profile."))
            }
            throw error
        }
    }

    init(deckId: DeckID, deckName: String, requiredActivationID: UUID? = nil) {
        @Dependency(\.ankiBackend) var backend
        collectionActivationID = requiredActivationID ?? backend.collectionActivationID
        self.deckId = deckId
        self.deckName = deckName
    }

    // MARK: - Derived presentation values

    var currentAlert: DeckConfigAlert? {
        if case .alert(let a) = destination { return a }
        return nil
    }

    var alertTitle: String {
        switch currentAlert {
        case .saveFailed: "Save failed"
        case .fsrsError: "FSRS"
        case .presetError: "Preset"
        case .createPreset: "New preset"
        case .renamePreset: "Rename preset"
        case .deletePresetConfirm: "Delete preset?"
        case nil: ""
        }
    }

    var hasLoadedConfig: Bool { loaded != nil }
    var currentPresetName: String? { loaded?.config.name }
    var deleteFallbackPresetName: String? { deleteFallbackPreset?.name }

    var presetOptions: [DeckConfigsForUpdate.ConfigWithExtra] {
        (loaded?.context.allConfig ?? [])
            .sorted { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
    }

    var selectedPresetID: DeckConfigID { loaded?.config.id ?? DeckConfigID(0) }

    var canDeletePreset: Bool {
        // Preset id 1 is the built-in Default preset and cannot be removed.
        selectedPresetID.rawValue != 0 && selectedPresetID.rawValue != 1 && presetOptions.count > 1
    }

    var deleteFallbackPreset: DeckConfig? {
        presetOptions.first(where: { $0.config.id.rawValue == 1 && $0.config.id != selectedPresetID })?.config
            ?? presetOptions.first(where: { $0.config.id != selectedPresetID })?.config
    }

    var presetUseCount: Int {
        loaded.flatMap { l in l.context.allConfig.first(where: { $0.config.id == l.config.id })?.useCount } ?? 0
    }

    var defaultParamSearch: String {
        let escaped = (loaded?.config.name ?? deckName)
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "preset:\"\(escaped)\" -is:suspended"
    }

    // MARK: - Load / save

    func loadConfig() async {
        isLoading = true
        loadError = nil
        do {
            let config = try await collectionAccess { try await deckClient.getDeckConfig(deckId) }
            let context = (try? await collectionAccess { try await deckClient.fetchDeckConfigContext(deckId) }) ?? fallbackContext(from: config)
            apply(config: config, context: context)
            isLoading = false
        } catch {
            loadError = "Failed to load deck options: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func apply(config: DeckConfig, context: DeckConfigsForUpdate) {
        loaded = LoadedConfig(config: config, context: context)
        let cfg = config.config
        newCardsPerDay = Int32(cfg.newPerDay)
        reviewsPerDay = Int32(cfg.reviewsPerDay)
        learningStepsText = formatSteps(cfg.learnSteps)
        relearningStepsText = formatSteps(cfg.relearnSteps)
        graduatingGoodDays = Int32(cfg.graduatingIntervalGood)
        graduatingEasyDays = Int32(cfg.graduatingIntervalEasy)
        leechThreshold = Int32(max(1, cfg.leechThreshold))
        leechAction = cfg.leechAction

        newCardsIgnoreReviewLimit = context.newCardsIgnoreReviewLimit
        applyAllParentLimits = context.applyAllParentLimits
        fsrsHealthCheck = context.fsrsHealthCheck
        fsrsEnabled = context.fsrs

        if let override = context.currentDeck?.limits?.desiredRetention {
            desiredRetentionPercent = Double(override * 100)
        } else {
            desiredRetentionPercent = cfg.desiredRetention > 0 ? Double(cfg.desiredRetention * 100) : 90
        }
        historicalRetentionPercent = cfg.historicalRetention > 0 ? Double(cfg.historicalRetention * 100) : 90

        fsrsWeightsText = formatWeights(currentWeights(from: cfg))
        fsrsParamSearch = cfg.paramSearch

        buryNew = cfg.buryNew
        buryReviews = cfg.buryReviews
        buryInterdayLearning = cfg.buryInterdayLearning

        newCardInsertOrder = cfg.newCardInsertOrder
        newCardGatherPriority = cfg.newCardGatherPriority
        newCardSortOrder = cfg.newCardSortOrder
        newMix = cfg.newMix
        reviewOrder = cfg.reviewOrder
        interdayLearningMix = cfg.interdayLearningMix

        showTimer = cfg.showTimer
        capAnswerTimeToSecs = Int32(max(5, cfg.capAnswerTimeToSecs))
        stopTimerOnAnswer = cfg.stopTimerOnAnswer

        secondsToShowQuestion = Double(cfg.secondsToShowQuestion)
        secondsToShowAnswer = Double(cfg.secondsToShowAnswer)
        questionAction = cfg.questionAction
        answerAction = cfg.answerAction

        maximumReviewIntervalDays = Int32(max(1, cfg.maximumReviewInterval))
        intervalMultiplierPercent = cfg.intervalMultiplier > 0 ? Double(cfg.intervalMultiplier * 100) : 100
        hardMultiplierPercent = cfg.hardMultiplier > 0 ? Double(cfg.hardMultiplier * 100) : 120
        easyMultiplierPercent = cfg.easyMultiplier > 0 ? Double(cfg.easyMultiplier * 100) : 130
        disableAutoplay = cfg.disableAutoplay
        waitForAudio = cfg.waitForAudio

        if cfg.easyDaysPercentages.count == 7 {
            easyDayPercentages = cfg.easyDaysPercentages.map { Double($0) * 100 }
        } else {
            easyDayPercentages = Array(repeating: 100, count: 7)
        }
    }

    /// Writes the edited form back through the engine. Returns `true` when
    /// the save succeeded so the Container can dismiss; sets a `.saveFailed`
    /// alert and returns `false` otherwise.
    func saveConfig() async -> Bool {
        guard let loaded else { return false }
        isSaving = true
        defer { isSaving = false }

        stepsParseError = nil
        let learnSteps = parseSteps(learningStepsText)
        let relearnSteps = parseSteps(relearningStepsText)
        // Refuse rather than silently write a shorter schedule: `parseSteps`
        // reports the tokens it could not read, and a dropped token here
        // becomes a lost interval in the user's collection.
        if let problem = stepsParseError {
            destination = .alert(.saveFailed(L10n.text("Enter learning steps like 10m 1d.")))
            Log.decks.error("Deck config save rejected: unparseable step(s) \(problem, privacy: .public)")
            return false
        }

        var updated = loaded.config
        var cfg = updated.config
        cfg.newPerDay = Int(max(0, newCardsPerDay))
        cfg.reviewsPerDay = Int(max(0, reviewsPerDay))
        cfg.learnSteps = learnSteps
        cfg.relearnSteps = relearnSteps
        cfg.graduatingIntervalGood = Int(max(0, graduatingGoodDays))
        cfg.graduatingIntervalEasy = Int(max(0, graduatingEasyDays))
        cfg.leechThreshold = Int(max(1, leechThreshold))
        cfg.leechAction = leechAction
        cfg.desiredRetention = Float(desiredRetentionPercent / 100)
        cfg.historicalRetention = Float(historicalRetentionPercent / 100)
        cfg.paramSearch = fsrsParamSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        cfg.buryNew = buryNew
        cfg.buryReviews = buryReviews
        cfg.buryInterdayLearning = buryInterdayLearning

        cfg.newCardInsertOrder = newCardInsertOrder
        cfg.newCardGatherPriority = newCardGatherPriority
        cfg.newCardSortOrder = newCardSortOrder
        cfg.newMix = newMix
        cfg.reviewOrder = reviewOrder
        cfg.interdayLearningMix = interdayLearningMix

        cfg.showTimer = showTimer
        cfg.capAnswerTimeToSecs = Int(max(5, capAnswerTimeToSecs))
        cfg.stopTimerOnAnswer = stopTimerOnAnswer

        cfg.secondsToShowQuestion = Float(max(0, secondsToShowQuestion))
        cfg.secondsToShowAnswer = Float(max(0, secondsToShowAnswer))
        cfg.questionAction = questionAction
        cfg.answerAction = answerAction

        cfg.maximumReviewInterval = Int(max(1, maximumReviewIntervalDays))
        cfg.intervalMultiplier = Float(intervalMultiplierPercent / 100)
        cfg.hardMultiplier = Float(hardMultiplierPercent / 100)
        cfg.easyMultiplier = Float(easyMultiplierPercent / 100)
        cfg.disableAutoplay = disableAutoplay
        cfg.waitForAudio = waitForAudio

        cfg.easyDaysPercentages = easyDayPercentages.map { Float(max(50, min(150, $0)) / 100) }

        if fsrsEnabled {
            let parsed = parseFloats(fsrsWeightsText)
            if !parsed.isEmpty {
                // Newer FSRS revisions write to params6; clear the older slots
                // so the backend uses the current generation.
                cfg.fsrsParams6 = parsed
                cfg.fsrsParams5 = []
                cfg.fsrsParams4 = []
            }
        } else {
            cfg.fsrsParams6 = []
            cfg.fsrsParams5 = []
            cfg.fsrsParams4 = []
        }

        updated.config = cfg

        do {
            try await collectionAccess { try await deckClient.updateDeckConfig(
                deckId,
                updated,
                applyToChildren,
                fsrsEnabled,
                newCardsIgnoreReviewLimit,
                applyAllParentLimits,
                fsrsHealthCheck
            ) }
            collectionStore.markLocalMutation()
            return true
        } catch {
            destination = .alert(.saveFailed(error.localizedDescription))
            return false
        }
    }

    // MARK: - Helpers

    func fallbackContext(from config: DeckConfig) -> DeckConfigsForUpdate {
        let cfg = config.config
        let fsrsBacked = !cfg.fsrsParams6.isEmpty || !cfg.fsrsParams5.isEmpty || !cfg.fsrsParams4.isEmpty
        return DeckConfigsForUpdate(
            allConfig: [DeckConfigsForUpdate.ConfigWithExtra(config: config, useCount: 0)],
            currentDeck: DeckConfigsForUpdate.CurrentDeck(name: deckName, configID: config.id),
            defaults: config,
            fsrs: fsrsBacked
        )
    }

    /// Anki stores learn/relearn steps as Float minutes. Accept "1m 10m 1h 1d"
    /// shorthand on input and emit "1m 10m" on output (matching the FSRS
    /// scheduler's expected unit).
}
