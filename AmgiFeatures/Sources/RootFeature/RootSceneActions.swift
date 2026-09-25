import Observation
import SwiftUI

/// Stable focused-scene command surface for application and browser menus.
/// A class keeps SwiftUI from rebuilding focused values on every root body
/// evaluation, and all commands target the window that is actually frontmost.
@MainActor
@Observable
final class RootSceneActions {
    var isReaderEnabled = true
    var selectSection: (MainSection) -> Void = { _ in }
    var presentSync: () -> Void = {}
    var presentImport: () -> Void = {}
    var presentExport: () -> Void = {}
    var presentStudyAssistant: () -> Void = {}

    func select(_ section: MainSection) {
        selectSection(section)
    }

    func sync() {
        presentSync()
    }

    func importFile() {
        presentImport()
    }

    func exportCollection() {
        presentExport()
    }

    func studyAssistant() {
        presentStudyAssistant()
    }

    func invalidate() {
        selectSection = { _ in }
        presentSync = {}
        presentImport = {}
        presentExport = {}
        presentStudyAssistant = {}
    }
}

private struct RootSceneActionsKey: FocusedValueKey {
    typealias Value = RootSceneActions
}

extension FocusedValues {
    var rootSceneActions: RootSceneActions? {
        get { self[RootSceneActionsKey.self] }
        set { self[RootSceneActionsKey.self] = newValue }
    }
}

/// A forwarded LaunchServices payload can be observed by every open scene.
/// Claim it once so exactly one window acts on the external request.
@MainActor
final class ForwardedURLClaim {
    static let shared = ForwardedURLClaim()

    private var owner: UUID?

    private init() {}

    func claim(for id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id
        return true
    }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }
}
