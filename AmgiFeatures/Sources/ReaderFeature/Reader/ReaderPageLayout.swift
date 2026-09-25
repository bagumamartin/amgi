import Foundation

/// Resolves the reader canvas from the space the surrounding UI actually
/// has available. Keeping this separate from the WebView hosts makes compact,
/// regular, single-page, and two-page behavior follow the same rules in both
/// the EPUB and note readers.
struct ReaderPageLayout: Equatable, Sendable {
    static let singlePageMaxWidth: CGFloat = 760
    static let spreadMaxWidth: CGFloat = 1_200
    static let spreadMinimumWidth: CGFloat = 920
    static let spreadMinimumHeight: CGFloat = 520

    let availableSize: CGSize
    let usesTwoPageLayout: Bool

    var columnCount: Int { usesTwoPageLayout ? 2 : 1 }

    /// The readable canvas. A single page is capped to a comfortable line
    /// length; a spread uses the available width up to the same total measure
    /// as two capped pages. Empty leading/trailing space is left to the host
    /// background so the text never stretches across an arbitrary window.
    var contentWidth: CGFloat {
        let maximum = usesTwoPageLayout ? Self.spreadMaxWidth : Self.singlePageMaxWidth
        return max(1, min(availableSize.width, maximum))
    }

    static func resolve(
        availableSize: CGSize,
        allowsTwoPageLayout: Bool
    ) -> ReaderPageLayout {
        let hasLandscapeSpreadRoom = availableSize.width >= spreadMinimumWidth
            && availableSize.height >= spreadMinimumHeight
            && availableSize.width > availableSize.height
        return ReaderPageLayout(
            availableSize: availableSize,
            usesTwoPageLayout: allowsTwoPageLayout && hasLandscapeSpreadRoom
        )
    }
}

/// A one-shot hardware-keyboard page request. The sequence number makes two
/// identical turns distinct so a representable can consume each key press.
struct ReaderPageTurnRequest: Equatable {
    let sequence: Int
    let direction: ReaderPageDirection
}

enum ReaderPageDirection: Equatable {
    case forward
    case backward
}
