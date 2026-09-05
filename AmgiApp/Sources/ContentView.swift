// AmgiApp/Sources/ContentView.swift
import SwiftUI
import AnkiKit
import AnkiSync
import Sharing
import Dependencies

/// App root. Hosts the tab bar (`MainTabView`) and orchestrates the
/// cross-cutting flows that sit above it: sync (sheet + toast), deck
/// import, and the review cover. Each flow lives in its own piece —
/// `MainTabView`, `SyncToastController`, `deckImport` — so the body stays a
/// thin composition.
struct ContentView: View {
    @Binding var pendingReviewDeckId: DeckID?

    @Dependency(\.syncCoordinator) private var coordinator
    @Dependency(\.collectionStore) private var store
    @Dependency(\.liveReviewCounts) private var liveCounts
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    @State private var syncToast = SyncToastController()
    @State private var modelDownloads = ModelDownloadCoordinator()
    @State private var showSync = false
    @State private var showImport = false
    @State private var refreshID = UUID()

    @Shared(.appStorage(ReaderPreferences.Keys.showTab))
    private var showReaderTab: Bool = true

    var body: some View {
        MainTabView(
            refreshID: refreshID,
            showReaderTab: showReaderTab,
            onSync: startSync,
            onImport: { showImport = true },
            onSelectStudyDeck: { pendingReviewDeckId = $0 }
        )
        .sheet(isPresented: $showSync) {
            store.invalidateAll()
            refreshID = UUID()          // still drives the tabs not yet on CollectionStore
        } content: {
            SyncSheet(isPresented: $showSync)
                .presentationDetents([.fraction(0.7), .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: SyncToastController.needsAttention(coordinator.state)) { _, needs in
            if needs && coordinator.shouldPresentAttention {
                coordinator.dismissAttention()
                showSync = true
            }
        }
        .onChange(of: coordinator.shouldPresentAttention) { _, needs in
            if needs {
                coordinator.dismissAttention()
                showSync = true
            }
        }
        .onChange(of: coordinator.state) { _, newState in
            syncToast.handle(newState)
            if case .success = newState { store.invalidateAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiPresentSync)) { _ in
            showSync = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiSyncConfigurationChanged)) { _ in
            coordinator.enableAutomaticSync()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiPerformBackgroundSync)) { _ in
            Task { await coordinator.startSync(isAutomatic: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            coordinator.setApplicationActive(phase == .active)
        }
        .task {
            coordinator.setApplicationActive(scenePhase == .active)
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
            sync: syncToast.toast,
            model: modelDownloads.toast,
            onModelRetry: { modelDownloads.retry() }
        )
        .deckImport(isPresented: $showImport) {
            store.invalidateAll()
            store.markLocalMutation(reason: "Deck import")
            refreshID = UUID()
        }
        #if os(macOS)
        .onChange(of: pendingReviewDeckId) { _, newValue in
            guard let deckId = newValue else { return }
            ReviewWindowQueue.shared.enqueue(deckId)
            openWindow(id: "review")
            pendingReviewDeckId = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiReviewFinished)) { _ in
            store.invalidateAll()
            store.markLocalMutation(reason: "Review completed")
            liveCounts.clear()
            refreshID = UUID()
        }
        #else
        .fullScreenCover(item: $pendingReviewDeckId) { deckId in
            ReviewView(deckId: deckId) {
                pendingReviewDeckId = nil
                store.invalidateAll()
                store.markLocalMutation(reason: "Review completed")
                liveCounts.clear()
                refreshID = UUID()
            }
        }
        #endif
    }

}

private extension ContentView {
    func startSync() {
        // The sheet owns the sync preflight, including server setup and the
        // login prompt. Present it before starting work so every entry point
        // (toolbar, menu command, and retry) follows the same auth flow.
        showSync = true
    }
}

extension Notification.Name {
    static let amgiPresentSync = Notification.Name("com.amgiapp.presentSync")
    static let amgiSyncConfigurationChanged = Notification.Name("com.amgiapp.syncConfigurationChanged")
    static let amgiPerformBackgroundSync = Notification.Name("com.amgiapp.performBackgroundSync")
    static let amgiReviewFinished = Notification.Name("com.amgiapp.reviewFinished")
}
