// AmgiApp/Sources/Shared/BrowseLauncher.swift
import SwiftUI
import Observation

/// In-process handoff for launching Browse from anywhere: Library drill-ins,
/// deck-detail actions, deep links. MainTabView observes `requestID` and
/// switches to the Browse section; BrowseView consumes `query` on appear.
///
/// A @MainActor singleton (not Shared/appStorage) — requests are transient,
/// single-shot, and meaningless across relaunches.
@MainActor
@Observable
final class BrowseLauncher {
    static let shared = BrowseLauncher()

    struct Request: Equatable {
        let query: String?
        let id = UUID()
    }

    private(set) var pending: Request?
    /// Observable counter MainTabView keys `.onChange` off.
    private(set) var requestID: UUID?

    /// Launches Browse, optionally seeded with a search string
    /// (e.g. `deck:"Name"` or a token-composed grammar fragment).
    func launch(query: String? = nil) {
        pending = Request(query: query)
        requestID = pending?.id
    }

    /// Consumed by BrowseView's onAppear/task; returns the seed exactly once.
    func consume() -> String? {
        guard let request = pending else { return nil }
        pending = nil
        return request.query
    }
}
