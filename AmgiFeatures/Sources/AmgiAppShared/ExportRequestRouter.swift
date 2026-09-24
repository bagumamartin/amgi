package import Foundation
import Observation
package import AnkiKit

package extension Notification.Name {
    static let amgiExportDidSave = Notification.Name("AmgiExportDidSave")
}

package struct ExportRequest: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let scope: ExportScope
    package let allowedFormats: [ExportFormat]
    package let allowsScopeChange: Bool
    package let sourceName: String?
    package let itemCount: Int?

    package init(
        scope: ExportScope,
        allowedFormats: [ExportFormat] = ExportFormat.allCases,
        allowsScopeChange: Bool = false,
        sourceName: String? = nil,
        itemCount: Int? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.scope = scope
        self.allowedFormats = allowedFormats
        self.allowsScopeChange = allowsScopeChange
        self.sourceName = sourceName
        self.itemCount = itemCount
    }
}

@MainActor
@Observable
package final class ExportRequestRouter {
    package static let shared = ExportRequestRouter()

    package private(set) var pending: ExportRequest?
    package private(set) var requestID: UUID?

    private init() {}

    package func request(_ request: ExportRequest) {
        pending = request
        requestID = request.id
    }

    package func request(
        scope: ExportScope,
        allowedFormats: [ExportFormat] = ExportFormat.allCases,
        allowsScopeChange: Bool = false,
        sourceName: String? = nil,
        itemCount: Int? = nil
    ) {
        request(ExportRequest(
            scope: scope,
            allowedFormats: allowedFormats,
            allowsScopeChange: allowsScopeChange,
            sourceName: sourceName,
            itemCount: itemCount
        ))
    }

    package func consume() -> ExportRequest? {
        defer { pending = nil }
        return pending
    }

    package func discardPending() {
        pending = nil
        requestID = nil
    }
}
