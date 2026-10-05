import AmgiAppCore
import AnkiClients
import AnkiKit
import Dependencies
import Foundation

extension DeckConfigModel {
    /// Learning/relearning steps, in minutes.
    ///
    /// Accepts `m` / `h` / `d` suffixes in either case and a bare number as
    /// minutes, and reads the decimal mark the *user's* locale uses — a
    /// German user typing "1,5" gets 1.5 minutes, not two dropped tokens.
    ///
    /// Tokens that are not numbers are skipped, but `stepsParseError` reports
    /// them so the screen can refuse the save instead of silently writing a
    /// shorter schedule. That silent drop is the real bug here: the previous
    /// `compactMap` turned "10m 1.5h" in a comma locale into `[10]` and wrote
    /// that to the collection as if the user had asked for it.
    func parseSteps(_ text: String) -> [Float] {
        var values: [Float] = []
        var rejected: [String] = []
        for token in Self.stepTokens(in: text) {
            if let value = Self.stepValue(token) {
                values.append(value)
            } else {
                rejected.append(token)
            }
        }
        stepsParseError = rejected.isEmpty ? nil : rejected.joined(separator: " ")
        return values
    }

    /// Splits into tokens on whitespace and on commas.
    ///
    /// A comma between two *digits* is part of the number ("1,5" is one and a
    /// half), because that is how a comma-decimal locale writes it. Every
    /// other comma separates, which is what keeps "1m, 10m" two steps.
    /// Thousands separators are not supported on purpose: the field is a
    /// short list, and accepting them would make "1,234" ambiguous between
    /// 1234 and 1.234.
    static func stepTokens(in text: String) -> [String] {
        let characters = Array(text)
        var tokens: [String] = []
        var current = ""
        for (offset, character) in characters.enumerated() {
            let isDecimalMark = character == ","
                && offset > 0
                && offset + 1 < characters.count
                && characters[offset - 1].isNumber
                && characters[offset + 1].isNumber
            if isDecimalMark || (character != "," && !character.isWhitespace) {
                current.append(character)
                continue
            }
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func stepValue(_ token: String) -> Float? {
        let lowered = token.lowercased()
        let suffixes: [(Character, Float)] = [("m", 1), ("h", 60), ("d", 1440)]
        for (suffix, multiplier) in suffixes where lowered.hasSuffix(String(suffix)) {
            guard let value = number(String(lowered.dropLast())) else { return nil }
            return value * multiplier
        }
        return number(lowered)
    }

    /// Reads a number written in the current locale's notation, and in the
    /// other common one — a settings field typed on a device that later
    /// switches languages should not reinterpret "1.5" as 15.
    private static func number(_ text: String) -> Float? {
        guard !text.isEmpty else { return nil }
        if let value = Float(text) { return value }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        if let value = formatter.number(from: text) { return value.floatValue }
        // Locale-aware read failed: try the opposite separator before giving
        // up, so a comma-locale user pasting an English "1.5" still works.
        guard let decimalSeparator = formatter.locale?.decimalSeparator,
              decimalSeparator != "."
        else { return nil }
        return Float(text.replacingOccurrences(of: decimalSeparator, with: "."))
    }

    func formatSteps(_ values: [Float]) -> String {
        guard !values.isEmpty else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        formatter.maximumFractionDigits = 0
        // No grouping. "1.440m" in a German locale would read back as 1.44
        // minutes, because this format deliberately has no thousands
        // separator to disambiguate it.
        formatter.usesGroupingSeparator = false
        return values
            .map { "\(formatter.string(from: NSNumber(value: $0)) ?? "\(Int($0))")m" }
            .joined(separator: " ")
    }

    /// FSRS weights. Tolerates the locale decimal mark for the same reason as
    /// `parseSteps`, and keeps the existing comma-separated list form.
    func parseFloats(_ text: String) -> [Float] {
        Self.stepTokens(in: text).compactMap { token in
            if let value = Float(token) { return value }
            return Self.number(token)
        }
    }

    func formatWeights(_ values: [Float]) -> String {
        // Weights round-trip through this field, so they are formatted in a
        // fixed, locale-independent notation: a weight written in one locale
        // must not become a different number in another.
        values.map { String(format: "%.4f", $0) }.joined(separator: ", ")
    }

    func currentWeights(from cfg: DeckConfig.Config) -> [Float] {
        if !cfg.fsrsParams6.isEmpty { return cfg.fsrsParams6 }
        if !cfg.fsrsParams5.isEmpty { return cfg.fsrsParams5 }
        return cfg.fsrsParams4
    }

    func effectiveParamSearch() -> String {
        let trimmed = fsrsParamSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultParamSearch : trimmed
    }

    /// Heuristic mirrored from upstream Anki: only relearning steps that fit
    /// inside one day are passed to the optimizer, so a "10m 1d" relearn
    /// schedule contributes 1, not 2.
    func relearningStepsInDay(_ steps: [Float]) -> UInt32 {
        var count: UInt32 = 0
        var accumulated: Float = 0
        for step in steps {
            accumulated += step
            if accumulated >= 1440 { break }
            count += 1
        }
        return count
    }

    // MARK: - Preset CRUD
}
