import Testing
import SwiftUI
@testable import SyncFeature

@Suite @MainActor struct ModelDownloadToastTests {
    @Test func progressStageTitlesAndFraction() {
        let downloading = ModelDownloadToast.Stage.downloading(fraction: 0.42, receivedBytes: 42_000_000, totalBytes: 100_000_000)
        #expect(downloading.title == "Downloading AI Model")
        #expect(downloading.fraction == 0.42)

        let verifying = ModelDownloadToast.Stage.verifying
        #expect(verifying.title == "Verifying Download…")
        #expect(verifying.fraction == 0)

        let extracting = ModelDownloadToast.Stage.extracting
        #expect(extracting.title == "Extracting Model…")

        let compiling = ModelDownloadToast.Stage.compiling
        #expect(compiling.title == "Compiling Neural Engine…")
    }

    @Test func toastViewCanBeInstantiated() {
        let progressToast = ModelDownloadToast(
            kind: .progress(.downloading(fraction: 0.5, receivedBytes: 50, totalBytes: 100))
        )
        _ = progressToast.body

        let successToast = ModelDownloadToast(
            kind: .success(title: "Ready", subtitle: "Smarter search enabled")
        )
        _ = successToast.body

        let failureToast = ModelDownloadToast(
            kind: .failure(message: "Failed", reason: "No network")
        )
        _ = failureToast.body
    }
}
