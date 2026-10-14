import SwiftUI

/// Separate, collection-free host for physical-device model acceptance tests.
@main
struct ModelGateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView("Model Validation", systemImage: "checkmark.seal", description: Text("This isolated app hosts Ijuka's native model tests. It does not open your collection."))
        }
    }
}
