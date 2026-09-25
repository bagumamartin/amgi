import SwiftUI
import Testing
@testable import BrowseFeature

#if os(macOS)

/// The AppKit canvas has the same commit-once contract as UIKit. These tests
/// stay model/coordinator-only so they run without a window server.
@Suite("ImageOcclusion macOS canvas")
@MainActor
struct ImageOcclusionMacCanvasTests {
    @Test("macOS coordinator commits a buffered drag once")
    func bufferedDragCommitsOnce() {
        var masks: [IOMask] = [
            .rect(left: 0.1, top: 0.1, width: 0.2, height: 0.2, extras: [:])
        ]
        var writes = 0
        let coordinator = OcclusionCanvasView.Coordinator(
            masks: Binding(
                get: { masks },
                set: {
                    writes += 1
                    masks = $0
                }
            ),
            selectedMaskIndex: .constant(nil),
            onRequestText: nil,
            onRequestTextEdit: nil,
            onAppend: nil,
            onSelectionChange: nil,
            onTransformDidBegin: nil,
            onTransformDidEnd: nil
        )

        coordinator.commitMasks(masks)
        #expect(writes == 0)

        coordinator.commitMasks([
            .rect(left: 0.5, top: 0.5, width: 0.2, height: 0.2, extras: [:])
        ])
        #expect(writes == 1)
    }
}

#endif
