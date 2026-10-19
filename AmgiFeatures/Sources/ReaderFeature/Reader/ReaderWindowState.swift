public import Observation
public import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Tells the app shell a book is open, so it can give the reader the whole
/// window: on Mac the section sidebar collapses (a PDF brings its own page
/// sidebar, Preview-style; an EPUB has none), and on iPad the tab sidebar
/// hides the way the tab bar already does on iPhone.
@MainActor
@Observable
public final class ReaderWindowState {
    public var isActive = false

    public init() {}
}

private struct ReaderWindowStateEnvironmentKey: EnvironmentKey {
    static let defaultValue: ReaderWindowState? = nil
}

public extension EnvironmentValues {
    var readerWindowState: ReaderWindowState? {
        get { self[ReaderWindowStateEnvironmentKey.self] }
        set { self[ReaderWindowStateEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Marks this screen as an open book for as long as it is on screen.
    func readerTakesWindow() -> some View {
        modifier(ReaderTakesWindowModifier())
    }
}

private struct ReaderTakesWindowModifier: ViewModifier {
    @Environment(\.readerWindowState) private var windowState

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background { TabSidebarHider().frame(width: 0, height: 0) }
            #endif
            .onAppear { windowState?.isActive = true }
            .onDisappear { windowState?.isActive = false }
    }
}

#if os(iOS)
/// Hides the iPad tab sidebar while the reader is up and puts it back as it
/// was. SwiftUI's adaptable `TabView` has no sidebar-visibility binding, but
/// it is a `UITabBarController` underneath, so the reader reaches it from its
/// own place in the hierarchy. On iPhone there is no sidebar and this is a
/// no-op.
private struct TabSidebarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var hiddenOn: UITabBarController?
        private var wasHidden = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard hiddenOn == nil, let tabs = tabBarController,
                  tabs.traitCollection.horizontalSizeClass == .regular else { return }
            wasHidden = tabs.sidebar.isHidden
            hiddenOn = tabs
            tabs.sidebar.isHidden = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            hiddenOn?.sidebar.isHidden = wasHidden
            hiddenOn = nil
        }
    }
}
#endif
