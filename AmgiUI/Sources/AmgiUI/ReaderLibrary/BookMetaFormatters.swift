public import Foundation

public enum BookMetaFormatters {
    public static func surname(from author: String?) -> String? {
        guard let author else { return nil }
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
    }

    public static func relativeReadingDate(_ date: Date, reference now: Date = .init(), locale: Locale = .current) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 * 60 * 24 { return AmgiL10n.text("Today", locale: locale) }
        if delta < 60 * 60 * 48 { return AmgiL10n.text("Yesterday", locale: locale) }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
