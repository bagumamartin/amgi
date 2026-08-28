public import SwiftUI
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
            .environment(\.startSync, start)
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

    private func start() {
        toast.presentSyncing()
        Task { await coordinator.startSync() }
    }
}

extension EnvironmentValues {
    /// Starts a sync. Installed by `.syncFlow()`; a no-op elsewhere, so a
    /// preview or test host renders the toolbar button without a coordinator.
    @Entry public var startSync: () -> Void = {}
}

extension View {
    /// Attach the sync flow. `onFinished` fires after the sheet is dismissed
    /// so the host can refresh anything not backed by `CollectionStore`.
    public func syncFlow(onFinished: @escaping () -> Void) -> some View {
        modifier(SyncFlowModifier(onFinished: onFinished))
    }
}
