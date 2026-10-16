import AmgiReader
import Foundation
#if canImport(UIKit) && !os(macOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What a reader does when one of its items in the selection menu is chosen.
///
/// Both readers fill this in. Only the source of the selection differs (the
/// EPUB page's script, PDFKit's `currentSelection`), so the menu itself and
/// what each item means stay identical between them.
@MainActor
struct ReaderSelectionMenuActions {
    struct HighlightColour {
        let title: String
        let color: PlatformColor
        let perform: () -> Void
    }

    var perform: (ReaderSelectionAction) -> Void
    var card: (ReaderCardMenuCommand) -> Void
    /// When non-empty, Highlight is a submenu of these colours rather than a
    /// single item. The PDF reader writes a colour into the annotation; the
    /// EPUB reader has one highlight style.
    var highlightColours: [HighlightColour] = []
}

/// The reader's items, merged into the platform's own selection menu.
///
/// There is exactly one menu on a selection: the system's. A second edit menu
/// beside it cannot work on iOS — only one is ever on screen, WebKit and
/// PDFKit re-present theirs every time a handle is let go, and the loser
/// vanishes. That is what made Make Card flash and disappear in the EPUB
/// reader, and why the PDF reader grew a separate bar that the waiting card
/// then covered. Merging also keeps the platform's own items (Translate,
/// Share, Writing Tools) and its placement next to the selection.
@MainActor
enum ReaderSystemSelectionMenu {
    /// The entries as they go into the system menu. Copy is dropped because
    /// the system menu already has it.
    static func entries(
        for payload: ReaderSelectionPayload,
        context: ReaderCardMenuContext
    ) -> [ReaderSelectionMenuEntry] {
        ReaderSelectionMenu.entries(for: payload, context: context)
            .filter { $0 != .action(.copy) }
    }

    /// Whether a system menu item is the platform's dictionary Look Up, which
    /// ours replaces: ours opens the in-app dictionary, where a card can be
    /// made from the result. Two items both titled "Look Up" would be a guess.
    static func isSystemLookUp(_ selector: Selector?) -> Bool {
        guard let selector else { return false }
        let name = NSStringFromSelector(selector).lowercased()
        return name.contains("define") || name.contains("lookup")
    }

    #if canImport(UIKit) && !os(macOS)
    private static let menuIdentifier = UIMenu.Identifier("app.amgi.reader.selection")

    static func elements(
        for entries: [ReaderSelectionMenuEntry],
        actions: ReaderSelectionMenuActions
    ) -> [UIMenuElement] {
        entries.map { element(for: $0, actions: actions) }
    }

    /// Puts the reader's items at the front of the system's edit menu.
    ///
    /// Called from `buildMenu(with:)` on the view that owns the selection
    /// (`ReaderWebView`, `ReaderPDFView`). Only context menus are touched — the
    /// same override is also asked to build the iPad's main menu bar.
    static func merge(_ elements: [UIMenuElement], into builder: any UIMenuBuilder) {
        guard builder.system == .context, !elements.isEmpty else { return }
        if builder.menu(for: .lookup) != nil {
            builder.replaceChildren(ofMenu: .lookup) { children in
                children.filter { !isSystemLookUp(($0 as? UICommand)?.action) }
            }
        }
        let menu = UIMenu(title: "", identifier: menuIdentifier, options: .displayInline, children: elements)
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }

    private static func element(
        for entry: ReaderSelectionMenuEntry,
        actions: ReaderSelectionMenuActions
    ) -> UIMenuElement {
        let image = UIImage(systemName: entry.systemImage)
        switch entry {
        case .action(.highlight) where !actions.highlightColours.isEmpty:
            return UIMenu(
                title: entry.title,
                image: image,
                children: actions.highlightColours.map { colour in
                    UIAction(
                        title: colour.title,
                        image: UIImage(systemName: "circle.fill")?
                            .withTintColor(colour.color, renderingMode: .alwaysOriginal)
                    ) { _ in colour.perform() }
                }
            )
        case .action(let action):
            return UIAction(title: entry.title, image: image) { _ in actions.perform(action) }
        case .card(let command, _, _):
            return UIAction(title: entry.title, image: image) { _ in actions.card(command) }
        case .submenu(_, _, let children):
            return UIMenu(
                title: entry.title,
                image: image,
                children: children.map { element(for: $0, actions: actions) }
            )
        }
    }
    #endif

    #if os(macOS)
    /// Puts the reader's items at the top of a context menu AppKit built.
    /// The EPUB host does the same for WebKit's menu in
    /// `EPUBPageViewControllerHost+macOS.swift`; this is the PDF reader's.
    static func merge(
        _ entries: [ReaderSelectionMenuEntry],
        actions: ReaderSelectionMenuActions,
        into menu: NSMenu
    ) {
        guard !entries.isEmpty else { return }
        for item in menu.items where isSystemLookUp(item.action) {
            menu.removeItem(item)
        }
        for (index, entry) in entries.enumerated() {
            menu.insertItem(item(for: entry, actions: actions), at: index)
        }
        if menu.items.count > entries.count {
            menu.insertItem(.separator(), at: entries.count)
        }
    }

    private static func item(
        for entry: ReaderSelectionMenuEntry,
        actions: ReaderSelectionMenuActions
    ) -> NSMenuItem {
        switch entry {
        case .action(.highlight) where !actions.highlightColours.isEmpty:
            let item = menuItem(entry.title, systemImage: entry.systemImage)
            let submenu = NSMenu(title: entry.title)
            for colour in actions.highlightColours {
                let child = menuItem(colour.title, run: colour.perform)
                child.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [colour.color]))
                submenu.addItem(child)
            }
            item.submenu = submenu
            return item
        case .action(let action):
            return menuItem(entry.title, systemImage: entry.systemImage) { actions.perform(action) }
        case .card(let command, _, _):
            return menuItem(entry.title, systemImage: entry.systemImage) { actions.card(command) }
        case .submenu(_, _, let children):
            let item = menuItem(entry.title, systemImage: entry.systemImage)
            let submenu = NSMenu(title: entry.title)
            for child in children { submenu.addItem(self.item(for: child, actions: actions)) }
            item.submenu = submenu
            return item
        }
    }

    private static func menuItem(
        _ title: String,
        systemImage: String? = nil,
        run: (() -> Void)? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
        if let run {
            // NSMenuItem holds its target weakly; the represented object keeps
            // the closure box alive for as long as the item exists.
            let target = MenuItemAction(run)
            item.target = target
            item.action = #selector(MenuItemAction.fire)
            item.representedObject = target
        }
        return item
    }

    @MainActor
    private final class MenuItemAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    #endif
}
