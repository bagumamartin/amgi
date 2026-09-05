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
    @State private var modelDownloads = ModelDownloadCoordinator()
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
            .onReceive(NotificationCenter.default.publisher(for: .amgiPresentSync)) { _ in
                SyncAction(toast: toast)()
            }
            .onReceive(NotificationCenter.default.publisher(for: .amgiPerformBackgroundSync)) { _ in
                // iOS automatic-sync background task: sync quietly, no sheet.
                Task { await coordinator.startSync() }
            }
            .task {
                modelDownloads.onAppear()
            }
            .onChange(of: NetworkMonitor.shared.isSatisfied) { _, _ in
                modelDownloads.retryIfAllowed()
            }
            .onChange(of: NetworkMonitor.shared.usesWiFi) { _, _ in
                modelDownloads.retryIfAllowed()
            }
            .confirmationDialog(
                modelDownloads.consent?.offline == true ? "You're Offline" : "Download AI Model?",
                isPresented: modelDownloads.consentBinding,
                titleVisibility: .visible
            ) {
                if modelDownloads.consent?.offline == true {
                    Button("OK") { modelDownloads.consentOfflineAcknowledged() }
                } else if modelDownloads.consent?.cellular == true {
                    Button("Download Anyway") { modelDownloads.consentDownload(allowExpensive: true) }
                    Button("Wait for Wi-Fi") { modelDownloads.consentWaitForWiFi() }
                    Button("Not Now", role: .cancel) { modelDownloads.consentNotNow() }
                } else {
                    Button("Download") { modelDownloads.consentDownload(allowExpensive: false) }
                    Button("Not Now", role: .cancel) { modelDownloads.consentNotNow() }
                }
            } message: {
                if modelDownloads.consent?.offline == true {
                    Text("The AI model powers smarter deck icons and meaning-based search. We'll ask again when you're back online — the app works fully without it.")
                } else if modelDownloads.consent?.cellular == true {
                    Text("\(modelDownloads.consentSizeText), and you're on mobile data — this may use your data plan. The app works fully without it; future updates follow your network setting in Maintenance.")
                } else {
                    Text("\(modelDownloads.consentSizeText) download. Powers smarter deck icons and meaning-based search — the app works fully without it. Future updates follow your network setting in Maintenance.")
                }
            }
            .combinedToastOverlay(
                sync: toast.toast,
                model: modelDownloads.toast,
                onModelRetry: { modelDownloads.retry() }
            )
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
///
/// Resolution timing note (2026-08-29): `callAsFunction()` resolves
/// `@Dependency(\.syncCoordinator)` at tap time, while `SyncFlowModifier`
/// resolves its own copy when the modifier is constructed. In the shipping
/// app these are the same instance — `bootstrap()` installs one coordinator
/// process-wide — so this never diverges today. It would diverge under a
/// `withDependencies { $0.syncCoordinator = fake }` scope wrapped around view
/// construction, the normal way a preview or test host injects a fake: the
/// modifier's `.onChange` handlers would observe the fake while a tap here
/// would still resolve the real one. Not fixed here — would mean storing the
/// coordinator in `SyncAction` alongside the toast, a real code change.
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
