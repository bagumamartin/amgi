import SwiftUI
#if canImport(UIKit)
package import UIKit
#elseif canImport(AppKit)
package import AppKit
#endif

// Platform colour/image aliases. View-level iOS-API shims live in AmgiUI
// (`MacOSSwiftUIShims.swift`) so every feature that already imports AmgiUI
// picks them up without an AmgiAppShared edge.

#if os(macOS)

package typealias PlatformColor = NSColor
package typealias PlatformImage = NSImage

extension Color {
    init(platformColor: NSColor) {
        self.init(nsColor: platformColor)
    }
}

extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}

#else

package typealias PlatformColor = UIColor
package typealias PlatformImage = UIImage

extension Color {
    init(platformColor: UIColor) {
        self.init(uiColor: platformColor)
    }
}

extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}

#endif
