package import Foundation
import AmgiAppCore
import Observation

/// One file selected from the Library picker or delivered by Finder/Files.
package struct ImportRequest: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let url: URL
    package let profileID: String

    package init(
        url: URL,
        profileID: String,
        id: UUID = UUID()
    ) {
        self.id = id
        self.url = url
        self.profileID = profileID
    }
}

/// Single in-process handoff for every import entry point. The root owns the
/// review sheet and the collection-replacement lifecycle; feature screens only
/// route a selected URL here.
@MainActor
@Observable
package final class ImportRequestRouter {
    package static let shared = ImportRequestRouter()

    package private(set) var pending: [ImportRequest] = []
    /// Observable counter the root keys its presentation update off.
    package private(set) var requestID: UUID?

    private init() {}

    package func request(_ url: URL) {
        let request = ImportRequest(url: url, profileID: AccountStore.shared.selectedID)
        pending.append(request)
        requestID = request.id
    }

    package func consume() -> ImportRequest? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    package func discardPending() {
        pending.removeAll()
        requestID = nil
    }
}
