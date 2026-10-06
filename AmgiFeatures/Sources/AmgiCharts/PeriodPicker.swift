import SwiftUI
import AmgiAppCore

public enum StatsPeriod: String, CaseIterable, Sendable {
    case day = "Today"
    case week = "7 Days"
    case month = "1 Month"
    case threeMonths = "3 Months"
    case year = "1 Year"
    case all = "All Time"

    public var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 31
        case .threeMonths: 92
        case .year: 365
        case .all: 36500
        }
    }

    public var shortLabel: String {
        switch self {
        case .day: "1D"
        case .week: "7D"
        case .month: "1M"
        case .threeMonths: "3M"
        case .year: "1Y"
        case .all: L10n.text("All")
        }
    }

    /// Localized menu title. `rawValue` stays English as the stable identity;
    /// views must render this, never `rawValue` — `Text(variable)` does not
    /// localize, so showing the raw value is how English leaked through.
    public var localizedTitle: String {
        switch self {
        case .day: L10n.text("Today")
        case .week: L10n.text("7 Days")
        case .month: L10n.text("1 Month")
        case .threeMonths: L10n.text("3 Months")
        case .year: L10n.text("1 Year")
        case .all: L10n.text("All Time")
        }
    }
}
