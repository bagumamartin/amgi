// AmgiApp/Sources/Shared/BrowseLauncher.swift
import SwiftUI
import Observation
public import AmgiAppCore
package import Foundation

/// In-process handoff for launching Browse from anywhere: Library drill-ins,
/// deck-detail actions, deep links. MainTabView observes `requestID` and
/// switches to the Browse section; BrowseView consumes `query` on appear.
///
/// A @MainActor singleton (not Shared/appStorage) — requests are transient,
/// single-shot, and meaningless across relaunches.
@MainActor
@Observable
package final class BrowseLauncher {
    package static let shared = BrowseLauncher()

    package struct Request: Equatable {
        package let query: String?
        package let deckID: Int64?
        package let profile: ProfileContext
        package let id = UUID()
    }

    private(set) var pending: Request?
    /// Observable counter MainTabView keys `.onChange` off.
    package private(set) var requestID: UUID?

    /// Launches Browse, optionally seeded with a search string
    /// (e.g. `deck:"Name"` or a token-composed grammar fragment).
    package func launch(query: String? = nil) {
        pending = Request(
            query: query,
            deckID: nil,
            profile: AccountStore.shared.selectedContext
        )
        requestID = pending?.id
    }

    package func launch(deckID: Int64) {
        pending = Request(
            query: nil,
            deckID: deckID,
            profile: AccountStore.shared.selectedContext
        )
        requestID = pending?.id
    }

    /// Drops a request that belonged to a previous profile activation.
    package func discardPending() {
        pending = nil
    }

    /// Consumed by BrowseView's onAppear/task; returns the seed exactly once.
    package func consumeRequest() -> Request? {
        guard let request = pending else { return nil }
        pending = nil
        guard request.profile.isCurrent(AccountStore.shared.selectedContext) else {
            return nil
        }
        return request
    }

    package func consume() -> String? {
        consumeRequest()?.query
    }
}
