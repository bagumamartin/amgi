public import SwiftUI

public extension View {
    /// Keeps macOS source lists readable while allowing wider user sizing.
    /// iPad retains the system's adaptive sidebar sizing.
    @ViewBuilder
    func appSidebarWidth() -> some View {
        #if os(macOS)
        navigationSplitViewColumnWidth(min: 240, ideal: 280)
        #else
        self
        #endif
    }
}
