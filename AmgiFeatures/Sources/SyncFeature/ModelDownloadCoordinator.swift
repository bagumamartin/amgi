import SwiftUI
import AmgiEmbeddings
import Foundation

/// Owns the e5 model download UX: first-launch consent ("always ask"),
/// policy-aware auto-retry, and the progress/success/failure toast.
///
/// Nothing downloads before explicit consent. When the model is already
/// installed, `onAppear` only runs the silent version check; upgrades then
/// follow the stored policy visibly (toast + cancel), never silently.
@Observable
@MainActor
final class ModelDownloadCoordinator {
    struct ConsentRequest: Identifiable, Equatable {
        let id = UUID()
        var byteSize: Int64?
        var offline: Bool
        var cellular: Bool
    }

    private(set) var consent: ConsentRequest?
    private(set) var toast: ModelDownloadToast.Kind?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// Suppresses the success toast when the model was already installed at
    /// launch — only transitions observed this session get announced.
    @ObservationIgnored private var announceReady = false

    var consentBinding: Binding<Bool> {
        Binding(get: { self.consent != nil }, set: { if !$0 { self.consent = nil } })
    }

    var consentSizeText: String {
        guard let bytes = consent?.byteSize, bytes > 0 else { return "≈200 MB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func onAppear() {
        NetworkMonitor.shared.start()
        guard !started else { return }
        started = true
        observeTask = Task { [weak self] in
            guard let self else { return }
            for await status in await ModelAssetManager.shared.observe() {
                self.handle(status)
            }
        }
        Task { [weak self] in await self?.initialFlow() }
    }

    // MARK: - Consent

    private func initialFlow() async {
        if ModelAssetManager.isModelInstalled {
            // Silent version check only; any upgrade follows policy + toast.
            await ModelAssetManager.shared.ensureModelAvailable(
                allowExpensiveNetwork: ModelDownloadPreferences.policy == .any
            )
            return
        }
        guard !ModelDownloadPreferences.consentGiven else { return }
        // Tiny JSON fetch for the exact size; offline lands in the offline
        // branch of the dialog instead of failing silently.
        do {
            let info = try await ModelAssetManager.shared.loadRemoteManifest()
            let monitor = NetworkMonitor.shared
            consent = ConsentRequest(
                byteSize: info.byteSize,
                offline: false,
                cellular: monitor.isSatisfied && !monitor.usesWiFi
            )
        } catch {
            consent = ConsentRequest(byteSize: nil, offline: true, cellular: false)
        }
    }

    func consentOfflineAcknowledged() {
        // Stay undecided — the next cold start asks again.
        consent = nil
    }

    func consentNotNow() {
        ModelDownloadPreferences.setConsentGiven(false)
        consent = nil
    }

    func consentWaitForWiFi() {
        ModelDownloadPreferences.setConsentGiven()
        ModelDownloadPreferences.setPolicy(.wifiOnly)
        consent = nil
    }

    func consentDownload(allowExpensive: Bool) {
        ModelDownloadPreferences.setConsentGiven()
        consent = nil
        Task {
            await ModelAssetManager.shared.ensureModelAvailable(
                allowExpensiveNetwork: allowExpensive
            )
        }
    }

    // MARK: - Retry

    /// Explicit user action (toast Retry, Settings): always allowed, even on
    /// expensive networks.
    func retry() {
        Task {
            await ModelAssetManager.shared.ensureModelAvailable(allowExpensiveNetwork: true)
        }
    }

    /// Called on connectivity changes: resumes a failed download only when
    /// consent exists and the stored policy allows the current path.
    func retryIfAllowed() {
        guard ModelDownloadPreferences.consentGiven, policyAllowsCurrentPath else { return }
        Task {
            if case .failed = await ModelAssetManager.shared.status {
                await ModelAssetManager.shared.ensureModelAvailable(
                    allowExpensiveNetwork: ModelDownloadPreferences.policy == .any
                )
            }
        }
    }

    private var policyAllowsCurrentPath: Bool {
        let monitor = NetworkMonitor.shared
        guard monitor.isSatisfied, !monitor.isConstrained else { return false }
        switch ModelDownloadPreferences.policy {
        case .wifiOnly: return monitor.usesWiFi && !monitor.isExpensive
        case .any: return true
        }
    }

    // MARK: - Toast mapping

    private func handle(_ status: ModelAssetManager.Status) {
        switch status {
        case .unknown, .notInstalled:
            announceReady = false
            cancelDismiss()
            toast = nil
        case .downloading(let fraction, let received, let total):
            announceReady = true
            cancelDismiss()
            toast = .progress(
                "Downloading AI model \(formatMB(received))/\(formatMB(total ?? 0)) · \(Int(fraction * 100))%"
            )
        case .verifying, .extracting, .compiling:
            announceReady = true
            cancelDismiss()
            toast = .progress("Preparing AI model\u{2026}")
        case .ready:
            cancelDismiss()
            if announceReady {
                announceReady = false
                toast = .success("AI model ready — smarter icons & search")
                dismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    if !(Task.isCancelled) { self?.toast = nil }
                }
            } else {
                toast = nil
            }
        case .failed:
            announceReady = false
            cancelDismiss()
            toast = .failure("AI model download failed")
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func formatMB(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}
