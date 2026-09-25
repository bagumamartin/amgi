package import Foundation
import Observation

/// Routes EPUB URLs delivered by Finder, Files, AirDrop, or drag-and-drop to
/// the Reader library. The root owns scene routing; the reader consumes the
/// request after its library model is ready.
@MainActor
@Observable
package final class ReaderImportRequestRouter {
    package static let shared = ReaderImportRequestRouter()

    package struct Request: Identifiable, Equatable, Sendable {
        package let id: UUID
        package let url: URL
        package let profileID: String

        package init(url: URL, profileID: String, id: UUID = UUID()) {
            self.id = id
            self.url = url
            self.profileID = profileID
        }
    }

    package private(set) var pending: [Request] = []
    package private(set) var requestID: UUID?

    private init() {}

    package func request(_ url: URL, profileID: String) {
        let request = Request(url: url, profileID: profileID)
        pending.append(request)
        requestID = request.id
    }

    package func consume(profileID: String) -> Request? {
        guard let index = pending.firstIndex(where: { $0.profileID == profileID }) else {
            return nil
        }
        return pending.remove(at: index)
    }

    package func discardPending() {
        pending.removeAll()
        requestID = nil
    }
}
