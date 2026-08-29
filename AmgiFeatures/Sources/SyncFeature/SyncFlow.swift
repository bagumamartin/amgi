package import SwiftUI
import AmgiAppShared
import Dependencies

/// The whole sync flow behind one modifier: the trigger (published as
/// `EnvironmentValues.startSync` so any toolbar below can fire it), the
/// progress/success toast, the sync sheet, and the collection invalidation
/// each of them implies.
///
/// It lives here rather than in the app root so `SyncCoordinator.state`,
/// `SyncSheet` and the toast controller can stay internal to this module —
/// the root used to drive all three by hand, which is what forced them
/// public.
private struct SyncFlowModifier: ViewModifier {
    let onFinished: () -> Void

    @Dependency(\.syncCoordinator) private var coordinator
    @Dependency(\.collectionStore) private var store

    @State private var toast = SyncToastController()
    @State private var showSheet = false

    func body(content: Content) -> some View {
        content
            .environment(\.startSync, SyncAction(toast: toast))
            .sheet(isPresented: $showSheet) {
                store.invalidateAll()
                onFinished()
            } content: {
                SyncSheet(isPresented: $showSheet)
                    .presentationDetents([.fraction(0.7), .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: SyncToastController.needsAttention(coordinator.state)) { _, needs in
                if needs { showSheet = true }
            }
            .onChange(of: coordinator.state) { _, newState in
                toast.handle(newState)
                if case .success = newState { store.invalidateAll() }
            }
            .syncToastOverlay(toast.toast)
    }
}

/// Starts a sync. Installed by `.syncFlow()`; a no-op elsewhere, so a preview
/// or test host renders the toolbar button without a coordinator.
///
/// A struct rather than a closure: SwiftUI cannot compare function values, so
/// the previous `() -> Void` entry made every reader — the tab bar's toolbar
/// — invalidate on each root body evaluation. The one stored property is a
/// class reference, which SwiftUI compares by identity, and `@State` in
/// `SyncFlowModifier` keeps a single instance, so the value is stable.
package struct SyncAction: Equatable {
    private let toast: SyncToastController?

    /// The uninstalled action: calling it does nothing.
    package init() { self.toast = nil }

    init(toast: SyncToastController) { self.toast = toast }

    var isInstalled: Bool { toast != nil }

    @MainActor
    package func callAsFunction() {
        guard let toast else { return }
        @Dependency(\.syncCoordinator) var coordinator
        toast.presentSyncing()
        Task { await coordinator.startSync() }
    }

    package static func == (lhs: SyncAction, rhs: SyncAction) -> Bool {
        lhs.toast === rhs.toast
    }
}

extension EnvironmentValues {
    @Entry package var startSync = SyncAction()
}

extension View {
    /// Attach the sync flow. `onFinished` fires after the sheet is dismissed
    /// so the host can refresh anything not backed by `CollectionStore`.
    package func syncFlow(onFinished: @escaping () -> Void) -> some View {
        modifier(SyncFlowModifier(onFinished: onFinished))
    }
}
