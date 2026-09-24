package import SwiftUI
package import AnkiKit

/// Compatibility name for older feature call sites. Export presentation is
/// owned by `ExportReviewView` and the root `ExportRequestRouter`; this wrapper
/// keeps the old sheet entry point source-compatible while using the same
/// format-aware review and native Save As flow.
package struct ExportPackagesSheet: View {
    private let request: ExportRequest

    package init(
        scope: ExportScope = .collection,
        allowedFormats: [ExportFormat] = ExportFormat.allCases,
        allowsScopeChange: Bool = true,
        sourceName: String? = nil,
        itemCount: Int? = nil
    ) {
        self.request = ExportRequest(
            scope: scope,
            allowedFormats: allowedFormats,
            allowsScopeChange: allowsScopeChange,
            sourceName: sourceName,
            itemCount: itemCount
        )
    }

    package var body: some View {
        ExportReviewView(request: request)
    }
}
