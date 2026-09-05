import Foundation
import Network

/// Shared connectivity snapshot. One `NWPathMonitor` for the process, started
/// on first access; the sync coordinator keeps its own private monitor for
/// its wifi-only policy, this one serves everything else (model downloads
/// today, anything network-gated tomorrow).
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isSatisfied = true
    private(set) var usesWiFi = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isSatisfied = path.status == .satisfied
                self?.usesWiFi = path.usesInterfaceType(.wifi)
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.amgiapp.network-monitor"))
    }
}
