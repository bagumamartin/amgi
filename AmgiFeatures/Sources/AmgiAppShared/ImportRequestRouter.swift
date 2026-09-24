package import Foundation
import Observation

/// One file selected from the Library picker or delivered by Finder/Files.
package struct ImportRequest: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let url: URL

    package init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
    }
}

/// Single in-process handoff for every import entry point. The root owns the
/// review sheet and the collection-replacement lifecycle; feature screens only
/// route a selected URL here.
@MainActor
@Observable
package final class ImportRequestRouter {
    package static let shared = ImportRequestRouter()

    package private(set) var pending: ImportRequest?
    /// Observable counter the root keys its presentation update off.
    package private(set) var requestID: UUID?

    private init() {}

    package func request(_ url: URL) {
        let request = ImportRequest(url: url)
        pending = request
        requestID = request.id
    }

    package func consume() -> ImportRequest? {
        defer { pending = nil }
        return pending
    }
}
