#if canImport(UIKit)
import UIKit

/// The platform's colour object type.
///
/// PDFKit's `PDFAnnotation.color` is `UIColor` on iOS and `NSColor` on macOS,
/// and the reader ships both. Naming the difference once keeps the annotation
/// code from carrying `#if` at every colour assignment.
typealias PlatformColor = UIColor
#else
import AppKit

typealias PlatformColor = NSColor
#endif

import PDFKit
import SwiftUI

extension PDFAnnotationColour {
    /// The colour as PDFKit wants it.
    ///
    /// Distinct from `swiftUIColor` because the two have different component
    /// accessors: `NSColor(srgbRed:green:blue:alpha:)` and
    /// `UIColor(red:green:blue:alpha:)` are not interchangeable, and using the
    /// wrong one produces a colour in the wrong space — which reads as "this
    /// yellow is not the same yellow" rather than as a build error.
    var platformColor: PlatformColor {
        let (r, g, b) = rgb
        #if canImport(UIKit) && !os(macOS)
        return PlatformColor(red: r, green: g, blue: b, alpha: 1)
        #else
        return PlatformColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #endif
    }
}


