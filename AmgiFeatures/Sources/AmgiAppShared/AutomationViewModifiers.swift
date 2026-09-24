public import AppIntents
public import SwiftUI

public extension View {
    /// Annotates onscreen content when App Intents entity annotation is
    /// available while preserving the app's iOS 18.0 deployment floor.
    @ViewBuilder
    func appEntityIdentifierIfAvailable(
        _ identifier: EntityIdentifier?
    ) -> some View {
        if #available(iOS 18.4, macOS 15.4, *) {
            appEntityIdentifier(identifier)
        } else {
            self
        }
    }

    /// Collection/list variant of ``appEntityIdentifierIfAvailable(_:)``.
    @ViewBuilder
    func appEntityIdentifierIfAvailable<Selection: Hashable>(
        forSelectionType itemType: Selection.Type = Selection.self,
        identifier: @escaping @Sendable (Selection) -> EntityIdentifier?
    ) -> some View {
        if #available(iOS 18.4, macOS 15.4, *) {
            appEntityIdentifier(
                forSelectionType: Selection.self,
                identifier: identifier
            )
        } else {
            self
        }
    }
}
