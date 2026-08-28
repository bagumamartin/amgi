public import AmgiAppShared
public import SwiftUI

/// The concrete `LookupPopupProviding` the app root injects.
///
/// Deliberately has no stored properties: SwiftUI compares environment values
/// field-by-field, so a fieldless struct always compares equal and readers of
/// `\.lookupPopup` never invalidate spuriously. Adding `Equatable` here would
/// be inert — the environment stores the boxed `any LookupPopupProviding`
/// existential, so SwiftUI reflects on that box either way, never on this
/// concrete type's own conformance.
public struct ReaderLookupPopup: LookupPopupProviding {
    public init() {}

    public func popup(query: String, onDismiss: @escaping () -> Void) -> AnyView {
        AnyView(LookupPopupView(initialQuery: query, onDismiss: onDismiss))
    }
}
