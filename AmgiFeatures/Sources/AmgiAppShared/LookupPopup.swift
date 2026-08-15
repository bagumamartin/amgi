public import SwiftUI

/// Builds the dictionary-lookup popup for a query, calling the second
/// argument when the popup should close.
public typealias LookupPopupBuilder = @MainActor (String, @escaping () -> Void) -> AnyView

public extension EnvironmentValues {
    /// Injection point for the reader's dictionary popup.
    ///
    /// `ReviewFeature` presents the same popup the reader does, but importing
    /// `ReaderFeature` for it dragged Review — and `DecksFeature` behind it —
    /// into the Cxx-interop chain, costing both targets explicit modules and
    /// compilation caching (rdar://122829880). The app root is in that chain
    /// regardless, so it supplies the real view here instead.
    ///
    /// Defaults to an empty view: a feature that renders without the app root
    /// (a preview, a test host) simply shows nothing rather than failing.
    @Entry var lookupPopup: LookupPopupBuilder = { _, _ in AnyView(EmptyView()) }
}
