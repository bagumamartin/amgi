import Testing
import SwiftUI
@testable import AmgiUI
@testable import AmgiTheme

@Suite("AmgiScreenCanvas")
struct AmgiScreenCanvasTests {
    @MainActor
    @Test func canvasBuilds() {
        _ = AmgiScreenCanvas()
            .environment(\.palette, .vividLight)
    }

    @MainActor
    @Test func modifierBuilds() {
        _ = Text("page")
            .amgiScreenCanvas()
            .environment(\.palette, .vividDark)
    }
}
