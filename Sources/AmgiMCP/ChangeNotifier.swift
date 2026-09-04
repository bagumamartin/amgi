import Foundation

/// Cross-process change signalling. After every successful mutation the
/// helper posts a distributed notification; the app observes it and
/// bumps its `CollectionStore` generation so every generation-keyed
/// screen reloads with the agent's edits immediately — no manual
/// refresh, no stale UI.
///
/// The notification carries no payload, which is all we need: the app
/// re-queries the collection it shares with this process.
enum ChangeNotifier {
    static let collectionChangedName = Notification.Name("com.amgi.collection.changed")

    static func postCollectionChanged() {
        // The Swift overlay only exposes the two-argument form;
        // delivery latency is irrelevant at UI-refresh granularity.
        DistributedNotificationCenter.default().post(
            name: collectionChangedName,
            object: nil
        )
    }
}
