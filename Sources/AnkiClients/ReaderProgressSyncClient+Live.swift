import AmgiReader
import AnkiKit
public import Dependencies
import Foundation

extension ReaderProgressSyncClient: DependencyKey {
    public static let liveValue: Self = {
        Self(
            loadManifest: {
                await ReaderProgressICloudStore.loadManifest(profileID: ProfileScope.current())
            },
            pushBookProgress: { bookID, payload in
                try await ReaderProgressICloudStore.pushBookProgress(
                    profileID: ProfileScope.current(),
                    bookID: bookID,
                    payload: payload
                )
            }
        )
    }()
}
