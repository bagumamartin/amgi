import SwiftUI

/// The complete Settings route catalogue.
///
/// Settings has two presentations (a drill-down page on iPhone/iPad and a
/// source list on macOS), but they must not grow separate lists of screens.
/// Keeping the route identity, title, icon, and group in one inventory makes
/// a new setting discoverable on every platform and gives the platform hosts
/// a small availability filter to apply.
enum SettingsRoute: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance
    case profiles
    case syncServer
    case reviewBehavior
    case cardRendering
    case shortcuts
    case assistant
    case readerDisplay
    case dictionaries
    case tags
    case database
    case backups
    case emptyCards
    case mediaCheck
    case manageTemplates
    case templateOverrides
    case codeEditor
    case agentMCP
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Theme & Appearance"
        case .profiles: "Profiles"
        case .syncServer: "Sync Server"
        case .reviewBehavior: "Review Behavior"
        case .cardRendering: "Card Rendering"
        case .shortcuts: "Shortcuts"
        case .assistant: "Study Assistant & System Search"
        case .readerDisplay: "Reader Display"
        case .dictionaries: "Dictionaries"
        case .tags: "Manage Tags"
        case .database: "Database"
        case .backups: "Backups"
        case .emptyCards: "Empty Cards"
        case .mediaCheck: "Media Check"
        case .manageTemplates: "Manage Templates"
        case .templateOverrides: "Template Overrides"
        case .codeEditor: "Code Editor"
        case .agentMCP: "Agent (MCP)"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .profiles: "person.crop.circle"
        case .syncServer: "arrow.triangle.2.circlepath"
        case .reviewBehavior: "graduationcap"
        case .cardRendering: "square.on.square"
        case .shortcuts: "keyboard"
        case .assistant: "sparkles"
        case .readerDisplay: "book"
        case .dictionaries: "character.book.closed"
        case .tags: "tag"
        case .database: "internaldrive"
        case .backups: "externaldrive"
        case .emptyCards: "tray"
        case .mediaCheck: "photo.on.rectangle"
        case .manageTemplates: "square.and.pencil"
        case .templateOverrides: "arrow.turn.down.right"
        case .codeEditor: "chevron.left.forwardslash.chevron.right"
        case .agentMCP: "cpu"
        case .about: "info.circle"
        }
    }

    var tone: SettingsTone {
        switch self {
        case .appearance: .mature
        case .profiles: .accent
        case .syncServer: .info
        case .reviewBehavior: .review
        case .cardRendering: .accent
        case .shortcuts: .learning
        case .assistant: .accent
        case .readerDisplay: .learning
        case .dictionaries: .danger
        case .tags: .neutral
        case .database: .info
        case .backups: .mature
        case .emptyCards: .danger
        case .mediaCheck: .learning
        case .manageTemplates: .learning
        case .templateOverrides: .neutral
        case .codeEditor: .link
        case .agentMCP: .info
        case .about: .accent
        }
    }

    /// Agent access is a Mac-only capability. The iOS implementation is
    /// intentionally a Mac-only explanation, so it is not presented as a
    /// dead route in the iPhone/iPad inventory.
    var isAvailable: Bool {
        switch self {
        case .agentMCP:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        default:
            return true
        }
    }
}

struct SettingsRouteGroup: Identifiable, Hashable, Sendable {
    let title: String
    let routes: [SettingsRoute]

    var id: String { title }
}

enum SettingsRouteInventory {
    /// Ordered exactly as the Settings source list should read on macOS.
    /// iPhone/iPad use the same routes in their drill-down sections.
    static let groups: [SettingsRouteGroup] = [
        SettingsRouteGroup(title: "Appearance", routes: [.appearance]),
        SettingsRouteGroup(title: "Account", routes: [.profiles, .syncServer]),
        SettingsRouteGroup(title: "Review", routes: [.reviewBehavior, .cardRendering, .shortcuts]),
        SettingsRouteGroup(title: "Apple Intelligence", routes: [.assistant]),
        SettingsRouteGroup(title: "Reader", routes: [.readerDisplay, .dictionaries]),
        SettingsRouteGroup(title: "Tags", routes: [.tags]),
        SettingsRouteGroup(title: "Maintenance", routes: [.database, .backups, .emptyCards, .mediaCheck]),
        SettingsRouteGroup(
            title: "Card Templates",
            routes: [.manageTemplates, .templateOverrides, .codeEditor]
        ),
        SettingsRouteGroup(title: "Agent", routes: [.agentMCP]),
        SettingsRouteGroup(title: "About", routes: [.about]),
    ]

    static var availableGroups: [SettingsRouteGroup] {
        groups.compactMap { group in
            let routes = group.routes.filter { $0.isAvailable }
            return routes.isEmpty ? nil : SettingsRouteGroup(title: group.title, routes: routes)
        }
    }

    static var availableRoutes: [SettingsRoute] {
        availableGroups.flatMap { $0.routes }
    }
}
