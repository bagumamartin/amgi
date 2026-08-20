import AnkiClients
import AnkiKit
import Dependencies
import Foundation

extension DeckConfigModel {
    func selectPreset(_ target: DeckConfig) async {
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            try await deckClient.selectDeckPreset(deckId, target, applyToChildren)
            await loadConfig()
        } catch {
            destination = .alert(.presetError("Failed to switch preset: \(error.localizedDescription)"))
        }
    }

    func createPreset() async {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let base = loaded?.config else { return }
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            try await deckClient.createDeckPreset(deckId, base, uniqueName(name), applyToChildren)
            newPresetName = ""
            await loadConfig()
        } catch {
            destination = .alert(.presetError("Failed to create preset: \(error.localizedDescription)"))
        }
    }

    func renamePreset() async {
        guard var base = loaded?.config else { return }
        let trimmed = renamePresetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            base.name = trimmed
            // Reuse selectDeckPreset which writes the existing config's row in
            // place — same RPC the Anki Desktop "rename preset" flow uses.
            try await deckClient.selectDeckPreset(deckId, base, applyToChildren)
            await loadConfig()
        } catch {
            destination = .alert(.presetError("Failed to rename preset: \(error.localizedDescription)"))
        }
    }

    func deletePreset() async {
        guard let current = loaded?.config, let fallback = deleteFallbackPreset else { return }
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            try await deckClient.deleteDeckPreset(deckId, current.id, fallback, applyToChildren)
            await loadConfig()
        } catch {
            destination = .alert(.presetError("Failed to delete preset: \(error.localizedDescription)"))
        }
    }

    func uniqueName(_ base: String) -> String {
        let existing = Set(presetOptions.map { $0.config.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - FSRS optimize

    func optimizeCurrentPreset() async {
        guard let loaded else { return }
        isOptimizingFsrs = true
        defer { isOptimizingFsrs = false }

        do {
            let cfg = loaded.config.config
            let edited = parseFloats(fsrsWeightsText)
            let request = FsrsOptimizeRequest(
                search: effectiveParamSearch(),
                currentWeights: FsrsWeights(edited.isEmpty ? currentWeights(from: cfg) : edited),
                relearningStepsPerDay: Int(relearningStepsInDay(parseSteps(relearningStepsText))),
                runHealthCheck: fsrsHealthCheck
            )

            let result = try await deckClient.computeFsrsParams(request)
            guard !result.weights.isEmpty else {
                destination = .alert(.fsrsError("Not enough review history to optimize. Try lowering historical retention or expanding the search."))
                return
            }
            fsrsWeightsText = formatWeights(result.weights.values)
            if result.healthCheck == .failed {
                destination = .alert(.fsrsError("Health check failed — review history may be inconsistent. Inspect parameters before saving."))
            }
        } catch {
            destination = .alert(.fsrsError(error.localizedDescription))
        }
    }

    func optimizeAllPresets() async {
        guard let loaded else { return }
        isOptimizingFsrs = true
        defer { isOptimizingFsrs = false }

        do {
            try await deckClient.optimizeFsrsPresets(deckId, loaded.config)
            await loadConfig()
        } catch {
            destination = .alert(.fsrsError(error.localizedDescription))
        }
    }

    // MARK: - FSRS simulator entry

    func openSimulator(mode: FsrsSimulatorMode) {
        guard let loaded else { return }
        let cfg = loaded.config.config
        let editedWeights = parseFloats(fsrsWeightsText)
        let weights = editedWeights.isEmpty ? currentWeights(from: cfg) : editedWeights
        guard !weights.isEmpty else {
            destination = .alert(.fsrsError("FSRS weights are empty. Run Optimize Weights first or save the preset."))
            return
        }
        let context = FsrsSimulatorContext(
            mode: mode,
            weights: weights,
            desiredRetentionPercent: desiredRetentionPercent,
            historicalRetentionPercent: historicalRetentionPercent,
            newCardsPerDay: Int(max(0, newCardsPerDay)),
            reviewsPerDay: mode == .workload ? 9999 : Int(max(0, reviewsPerDay)),
            maxIntervalDays: 36500,
            search: effectiveParamSearch(),
            ignoreNewLimit: newCardsIgnoreReviewLimit,
            suspendLeeches: leechAction == .suspend,
            leechThreshold: Int(max(1, leechThreshold)),
            learningStepCount: parseSteps(learningStepsText).count,
            relearningStepCount: parseSteps(relearningStepsText).count
        )
        destination = .sheet(.simulator(context))
    }
}
