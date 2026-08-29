public import SwiftUI

/// Supplies the reader's dictionary popup to features that must not import
/// `ReaderFeature`.
///
/// A protocol rather than a stored closure: SwiftUI cannot compare function
/// values, so the previous `LookupPopupBuilder` typealias made every reader
/// of `\.lookupPopup` invalidate on each root body evaluation. Conforming
/// types must have no stored properties, so the environment value compares
/// equal across evaluations.
///
/// `AnyView` is deliberate — erasing the reader's view type across the module
/// boundary is the point of this key, and this is a single leaf presentation
/// site, not a per-row cost.
///
/// Conforming types need no `Equatable` conformance. SwiftUI compares struct
/// environment values field-by-field, so a conformer with zero stored
/// properties compares equal by reflection regardless — `Equatable` is a fast
/// path here, not a prerequisite.
///
/// This "no stored properties" rule is a convention, not something the
/// compiler enforces. If you're adding a second conformer: giving it even one
/// stored property (a `String`, a closure, anything) silently reintroduces
/// the per-body-evaluation invalidation this design exists to remove — every
/// reader of `\.lookupPopup` invalidates again, with no test and no warning
/// to catch it.
@MainActor
public protocol LookupPopupProviding {
    func popup(query: String, onDismiss: @escaping () -> Void) -> AnyView
}

public extension EnvironmentValues {
    /// Injection point for the reader's dictionary popup.
    ///
    /// `ReviewFeature` presents the same popup the reader does, but importing
    /// `ReaderFeature` for it dragged Review — and `DecksFeature` behind it —
    /// into the Cxx-interop chain, costing both targets explicit modules and
    /// compilation caching (rdar://122829880). The app root is in that chain
    /// regardless, so it supplies the real provider here instead.
    ///
    /// `nil` means no provider: a feature that renders without the app root
    /// (a preview, a test host) shows nothing rather than failing.
    @Entry var lookupPopup: (any LookupPopupProviding)? = nil
}
