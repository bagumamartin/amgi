import CoreML
import CryptoKit
import Foundation
import ZIPFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Owns the e5-small CoreML weight lifecycle.
///
/// The ~200MB weight archive is NOT bundled (it would bloat every install and
/// can't live in git on a public fork). Instead the app fetches it once from
/// the asset CDN (after explicit user consent) and installs it into the
/// app-group container, versioned so future model swaps clean up after
/// themselves:
///
/// ```
/// <group>/AmgiEmbeddings/models/v1/MultilingualE5Small.mlmodelc/
/// <group>/AmgiEmbeddings/models/v1/receipt.json
/// ```
///
/// `TextEmbedder` reads the installed model through
/// `installedCompiledModelURL()`; until the install completes every consumer
/// degrades gracefully (name-token icon matching, no semantic fallback), so
/// this manager must never block app startup — `ensureModelAvailable()` is
/// driven by the app's consent coordinator, never fired blindly.
public actor ModelAssetManager {
    public static let shared = ModelAssetManager()

    /// CDN manifest endpoint. The manifest's `url` may be relative — it is
    /// resolved against this URL.
    public let manifestURL: URL

    public init(
        manifestURL: URL = URL(string: "https://amgiassets.bagumamartin.com/manifest.json")!
    ) {
        self.manifestURL = manifestURL
    }

    // MARK: - Status

    public enum Status: Sendable, Equatable {
        case unknown
        case notInstalled
        case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64?)
        case verifying
        case extracting
        case compiling
        case ready(Int)
        case failed(String)
    }

    public private(set) var status: Status = .unknown

    /// Subscribes to status changes. The current status is yielded immediately,
    /// then every transition until the stream terminates (cancelling the
    /// consuming task unregisters the observer).
    public func observe() -> AsyncStream<Status> {
        let current = status
        return AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private var observers: [UUID: AsyncStream<Status>.Continuation] = [:]

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func setStatus(_ next: Status) {
        status = next
        for continuation in observers.values { continuation.yield(next) }
        // Terminal transitions only (progress fractions would spam): lets
        // plain NotificationCenter observers (Settings rows) refresh without
        // holding a stream task.
        switch next {
        case .ready, .notInstalled, .failed:
            NotificationCenter.default.post(name: .amgiModelAssetChanged, object: nil)
        default:
            break
        }
        #if DEBUG
        print("[ModelAsset] \(next)")
        #endif
    }

    // MARK: - Install locations (shared with TextEmbedder)

    static let compiledDirName = "MultilingualE5Small.mlmodelc"
    static let receiptName = "receipt.json"

    /// Resume-data sidecar for an interrupted download, stored at the models
    /// root (NOT staging — staging is wiped on every exit including cancel).
    /// Versioned by filename so a manifest bump invalidates stale state.
    nonisolated static func resumeFile(version: Int) -> URL {
        modelsRootURL.appendingPathComponent(".resume-v\(version).dat", isDirectory: false)
    }

    /// Test hook: redirects the entire store into a scratch directory so
    /// tests never touch the real install. Test-only — production leaves
    /// this nil.
    public nonisolated(unsafe) static var modelsRootOverride: URL?

    /// Group-container root for all model versions:
    /// `<group>/AmgiEmbeddings/models`, next to the `AnkiCollection` root —
    /// one visible home for all Amgi data instead of scattered sandboxes.
    /// Falls back to sandbox Application Support when the group container
    /// is unavailable (unentitled contexts: `swift test`, previews).
    /// Excluded from backup — a re-downloadable 200MB asset must not burn
    /// iCloud quota.
    public nonisolated static var modelsRootURL: URL {
        if let override = modelsRootOverride { return override }
        if let groupModels = groupContainerModelsRoot() { return groupModels }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmgiEmbeddings", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Resolves `<group>/AmgiEmbeddings/models` via the entitled container.
    /// The group ID is platform-dependent — kept in sync with
    /// `AppGroup.identifier` (AmgiTheme) and the `APP_GROUP_IDENTIFIER`
    /// build setting by hand; this package must not depend on AmgiTheme
    /// (wrong direction) or AnkiKit (Rust-linked) for six lines.
    nonisolated static func groupContainerModelsRoot() -> URL? {
        #if os(macOS)
        let groupID = "39557WW39R.group.com.bagumamartin.AmgiApp"
        #else
        let groupID = "group.com.bagumamartin.AmgiApp"
        #endif
        guard let groupDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else { return nil }
        return groupDir
            .appendingPathComponent("AmgiEmbeddings", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// One-time moves into the group container, oldest first:
    /// sandbox `AmgiIcons/models` (pre-2026-09 package layout) then sandbox
    /// `AmgiEmbeddings/models` (pre-group layout). The app never shipped
    /// either layout, so these only ever fire on dev machines.
    nonisolated static func migrateLegacyStoreIfNeeded() {
        // Nowhere to migrate to without the group container (unentitled
        // contexts fall back to the sandbox copy in place).
        guard let destination = groupContainerModelsRoot() else { return }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyRoots = [
            appSupport
                .appendingPathComponent("AmgiIcons", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true),
            appSupport
                .appendingPathComponent("AmgiEmbeddings", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true),
        ]
        for legacyModels in legacyRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: legacyModels.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? fm.moveItem(at: legacyModels, to: destination)
            let legacyParent = legacyModels.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(at: legacyParent, includingPropertiesForKeys: nil))?.isEmpty == true {
                try? fm.removeItem(at: legacyParent)
            }
        }
    }

    nonisolated static func versionDir(version: Int) -> URL {
        modelsRootURL.appendingPathComponent("v\(version)", isDirectory: true)
    }

    nonisolated static func compiledModelURL(version: Int) -> URL {
        versionDir(version: version)
            .appendingPathComponent(compiledDirName, isDirectory: true)
    }

    /// Highest installed version whose compiled model exists on disk, if any.
    public nonisolated static func installedVersion() -> Int? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: modelsRootURL, includingPropertiesForKeys: nil
        ) else { return nil }
        var best: Int?
        for url in entries where url.lastPathComponent.hasPrefix("v") {
            guard let version = Int(url.lastPathComponent.dropFirst()) else { continue }
            var isDir: ObjCBool = false
            let compiled = url.appendingPathComponent(compiledDirName, isDirectory: true)
            guard fm.fileExists(atPath: compiled.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if best == nil || version > best! { best = version }
        }
        return best
    }

    /// Compiled model ready for `MLModel(contentsOf:)`, preferring the newest
    /// installed version. Used by `TextEmbedder`; nil until the CDN install
    /// (or a dev-machine bundled copy) exists.
    public nonisolated static func installedCompiledModelURL() -> URL? {
        guard let version = installedVersion() else { return nil }
        return compiledModelURL(version: version)
    }

    /// Engine-gated tests and UI use this to skip/degrade without touching the actor.
    public nonisolated static var isModelInstalled: Bool {
        installedCompiledModelURL() != nil
    }

    /// On-disk size of the installed model, for Settings display. Nil when absent.
    public nonisolated static func installedSizeBytes() -> Int64? {
        guard let root = installedCompiledModelURL() else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        return total
    }

    // MARK: - Entry point

    private var inFlight = false
    private var userCancelled = false
    private var activeTask: URLSessionDownloadTask?
    private var activeVersion: Int?
    private var activeStagingDir: URL?
    private var resumeData: Data?

    /// Ensures the model from the CDN manifest is installed. Idempotent and
    /// safe to call on every launch: returns immediately when the manifest
    /// version is already installed or a download is in flight. Never throws —
    /// failures land in `status` (`.failed`) for UI retry, and every embedder
    /// consumer already degrades while the model is absent.
    public func ensureModelAvailable(allowExpensiveNetwork: Bool = false) async {
        if inFlight { return }
        if Self.modelsRootOverride == nil { Self.migrateLegacyStoreIfNeeded() }
        if let installed = Self.installedVersion() {
            // Fast path, but still check the manifest: a version bump must
            // trigger an upgrade download rather than sitting on stale weights.
            do {
                let manifest = try await fetchManifest()
                if manifest.version <= installed {
                    setStatus(.ready(installed))
                    return
                }
            } catch {
                // Manifest unreachable — stay on the installed model; the next
                // launch retries. Never surface this as a failure when a good
                // model is already on disk.
                setStatus(.ready(installed))
                return
            }
        }
        inFlight = true
        userCancelled = false
        defer {
            inFlight = false
            activeTask = nil
            activeVersion = nil
            activeStagingDir = nil
        }
        do {
            let manifest = try await fetchManifest()
            if let installed = Self.installedVersion(), manifest.version <= installed {
                setStatus(.ready(installed))
                return
            }
            try await downloadAndInstall(manifest: manifest, allowExpensiveNetwork: allowExpensiveNetwork)
        } catch {
            if userCancelled || error is CancellationError {
                userCancelled = false
                setStatus(.notInstalled)
            } else {
                setStatus(.failed(error.localizedDescription))
            }
        }
    }

    /// Cancels an in-flight download (user action or pre-retry reset).
    /// Produces resume data when the server cooperates, so the next
    /// `ensureModelAvailable()` continues where it stopped instead of
    /// restarting. Status returns to `.notInstalled` — neutral, not an error.
    /// No-op when nothing is downloading.
    public func cancelDownload() {
        #if DEBUG
        print("[ModelAsset] cancel requested, inFlight=\(inFlight), taskState=\(activeTask.map { "\($0.state.rawValue)" } ?? "nil")")
        #endif
        guard inFlight, let task = activeTask else { return }
        userCancelled = true
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { await self?.storeResumeData(data) }
        })
    }

    private func storeResumeData(_ data: Data?) {
        resumeData = data
        // Persist at the models root so a relaunch (not just a same-process
        // retry) can resume: downloadAndInstall reads it back, and the
        // staging wipe can't touch it. Best-effort — absence means fresh.
        if let data, let version = activeVersion {
            try? data.write(to: Self.resumeFile(version: version))
        }
    }

    /// Deletes every installed model version (Settings reclaim-space). The
    /// next `ensureModelAvailable()` re-downloads.
    public func removeInstalledModel() async throws {
        let fm = FileManager.default
        let root = Self.modelsRootURL
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        await TextEmbedder.shared.resetEngineForModelInstall()
        setStatus(.notInstalled)
    }

    // MARK: - Manifest

    struct RemoteManifest: Codable, Sendable {
        var version: Int
        var url: String
        var sha256: String
        var byteSize: Int64
    }

    /// Consent-dialog payload: what the CDN currently offers, without
    /// starting a download. Throws when offline or the manifest is bad —
    /// the coordinator turns that into the offline branch of the dialog.
    public struct ManifestInfo: Sendable, Equatable {
        public var version: Int
        public var byteSize: Int64
    }

    public func loadRemoteManifest() async throws -> ManifestInfo {
        let manifest = try await fetchManifest()
        return ManifestInfo(version: manifest.version, byteSize: manifest.byteSize)
    }

    private func fetchManifest() async throws -> RemoteManifest {
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelAssetError.badManifest("manifest HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        do {
            return try JSONDecoder().decode(RemoteManifest.self, from: data)
        } catch {
            throw ModelAssetError.badManifest("undecodable manifest: \(error.localizedDescription)")
        }
    }

    /// Resolves the manifest's archive reference: absolute URLs pass through,
    /// relative paths resolve against the manifest endpoint itself.
    func archiveURL(for manifest: RemoteManifest) throws -> URL {
        if let absolute = URL(string: manifest.url), absolute.scheme != nil { return absolute }
        guard let resolved = URL(string: manifest.url, relativeTo: manifestURL)?.absoluteURL else {
            throw ModelAssetError.badManifest("unresolvable archive URL: \(manifest.url)")
        }
        return resolved
    }

    // MARK: - Download + install

    private func downloadAndInstall(manifest: RemoteManifest, allowExpensiveNetwork: Bool) async throws {
        let fm = FileManager.default
        let root = Self.modelsRootURL
        #if DEBUG
        print("[ModelAsset] installing into \(root.path), override=\(Self.modelsRootOverride?.path ?? "nil")")
        #endif
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)

        let versionDir = Self.versionDir(version: manifest.version)
        let stagingDir = root.appendingPathComponent(".staging-v\(manifest.version)", isDirectory: true)
        // Pick up resume data from a previous cancelled/interrupted download
        // of THIS manifest version (memory first, then the persisted sidecar).
        // Anything else — older versions, corrupt data — falls back to fresh.
        if resumeData == nil {
            resumeData = try? Data(contentsOf: Self.resumeFile(version: manifest.version))
        }
        if fm.fileExists(atPath: stagingDir.path) { try? fm.removeItem(at: stagingDir) }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        activeVersion = manifest.version
        activeStagingDir = stagingDir
        defer { try? fm.removeItem(at: stagingDir) }

        let archiveURL = try archiveURL(for: manifest)
        let zipURL = stagingDir.appendingPathComponent("model.zip", isDirectory: false)

        setStatus(.downloading(fraction: 0, receivedBytes: 0, totalBytes: manifest.byteSize))
        #if canImport(UIKit)
        let bgID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "AmgiModelDownload")
        }
        defer {
            Task { @MainActor in
                if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID) }
            }
        }
        #endif
        try await downloadFile(
            from: archiveURL,
            to: zipURL,
            expectedTotal: manifest.byteSize,
            allowExpensiveNetwork: allowExpensiveNetwork
        )
        // Download verified complete below — resume state is spent either way.
        resumeData = nil
        try? fm.removeItem(at: Self.resumeFile(version: manifest.version))

        setStatus(.verifying)
        try verifyDownload(at: zipURL, manifest: manifest)

        setStatus(.extracting)
        let unpackedDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
        try fm.unzipItem(at: zipURL, to: unpackedDir)
        guard let packageURL = findPackage(in: unpackedDir) else {
            throw ModelAssetError.noPackageInArchive
        }

        setStatus(.compiling)
        let compiledTemp = try await MLModel.compileModel(at: packageURL)
        defer { try? fm.removeItem(at: compiledTemp) }
        if fm.fileExists(atPath: versionDir.path) { try fm.removeItem(at: versionDir) }
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try fm.moveItem(at: compiledTemp, to: Self.compiledModelURL(version: manifest.version))
        let receipt = try JSONEncoder().encode(manifest)
        try receipt.write(to: versionDir.appendingPathComponent(Self.receiptName))

        pruneOlderVersions(keeping: manifest.version)
        await TextEmbedder.shared.resetEngineForModelInstall()
        setStatus(.ready(manifest.version))
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }

    /// Depth-first search for the first `*.mlpackage` directory. The zip is
    /// expected to contain one top-level package folder, but matching by
    /// extension keeps this robust to repackaging.
    private func findPackage(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension == "mlpackage",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            return url
        }
        return nil
    }

    private func pruneOlderVersions(keeping version: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.modelsRootURL, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix(".resume-v"), name != ".resume-v\(version).dat" {
                try? fm.removeItem(at: url)
                continue
            }
            guard name.hasPrefix("v"), name != "v\(version)",
                  Int(name.dropFirst()) != nil
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private func verifyDownload(at url: URL, manifest: RemoteManifest) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        guard size == manifest.byteSize else {
            throw ModelAssetError.sizeMismatch(expected: manifest.byteSize, actual: size)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else {
            throw ModelAssetError.checksumMismatch
        }
    }

    // MARK: - Download transport

    /// Downloads the archive, resuming from `resumeData` when present (server
    /// must cooperate — resume data the server rejects throws immediately, in
    /// which case we fall back to exactly one fresh attempt). Progress is
    /// reported against the manifest's authoritative byte size.
    private func downloadFile(
        from url: URL,
        to destination: URL,
        expectedTotal: Int64,
        allowExpensiveNetwork: Bool
    ) async throws {
        do {
            try await performDownload(
                from: url,
                to: destination,
                expectedTotal: expectedTotal,
                allowExpensiveNetwork: allowExpensiveNetwork,
                resumeData: resumeData
            )
        } catch {
            // A rejected resume blob must not poison the retry: drop it and
            // go fresh once. A user cancel must NEVER retry — resuming here
            // would defeat the cancel (the resume data it just produced
            // would immediately restart the transfer). Cancelled errors
            // rethrow so ensureModelAvailable() lands on `.notInstalled`.
            guard !userCancelled, resumeData != nil else { throw error }
            resumeData = nil
            if let version = activeVersion {
                try? FileManager.default.removeItem(at: Self.resumeFile(version: version))
            }
            try await performDownload(
                from: url,
                to: destination,
                expectedTotal: expectedTotal,
                allowExpensiveNetwork: allowExpensiveNetwork,
                resumeData: nil
            )
        }
    }

    private func performDownload(
        from url: URL,
        to destination: URL,
        expectedTotal: Int64,
        allowExpensiveNetwork: Bool,
        resumeData: Data?
    ) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = allowExpensiveNetwork
        configuration.allowsConstrainedNetworkAccess = allowExpensiveNetwork
        configuration.timeoutIntervalForRequest = 60
        let delegate = ModelDownloadDelegate(destination: destination) { [weak self] received, _ in
            Task { await self?.updateProgress(received: received, total: expectedTotal) }
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: url)
            }
            activeTask = task
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                delegate.continuation = continuation
                delegate.task = task
                task.resume()
            }
            activeTask = nil
        } catch {
            activeTask = nil
            try? FileManager.default.removeItem(at: destination)
            throw ModelAssetError.downloadFailed(error.localizedDescription)
        }
    }

    private func updateProgress(received: Int64, total: Int64) {
        // Only meaningful mid-download; terminal states own the status.
        guard case .downloading = status else { return }
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
        setStatus(.downloading(fraction: fraction, receivedBytes: received, totalBytes: total))
    }
}

// MARK: - Download delegate

/// `URLSessionDownloadDelegate` bridge with progress reporting. State is only
/// touched from the session's serial delegate queue except `continuation`,
/// which is set before `resume()` and therefore happens-before any callback.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    /// Reports raw byte counts; the manager maps them onto the manifest total.
    let onProgress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, any Error>?
    weak var task: URLSessionDownloadTask?

    private let lock = NSLock()
    private var completed = false
    private var lastReported: Int64 = -1

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        // Resume-aware throttle: report every ~1MB or at completion, not per
        // 1% — byte counts are what the UI renders, fractions derive later.
        let shouldReport = totalBytesWritten - lastReported >= (1 << 20)
            || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite)
        if shouldReport { lastReported = totalBytesWritten }
        lock.unlock()
        if shouldReport { onProgress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        lock.unlock()

        do {
            guard let http = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                throw ModelAssetError.httpError((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        #if DEBUG
        print("[ModelAsset] task completed, error=\(error.map { "\($0)" } ?? "nil")")
        #endif
        guard let error else { return }
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

extension Notification.Name {
    /// Posted on terminal model-asset transitions (ready / notInstalled /
    /// failed). Coarse companion to `ModelAssetManager.observe()` for
    /// observers that only need a refresh nudge.
    public static let amgiModelAssetChanged = Notification.Name("com.amgiapp.modelAssetChanged")
}

// MARK: - Errors

enum ModelAssetError: LocalizedError {
    case badManifest(String)
    case downloadFailed(String)
    case httpError(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case noPackageInArchive

    var errorDescription: String? {
        switch self {
        case .badManifest(let detail): "Model manifest error: \(detail)"
        case .downloadFailed(let detail): "Model download failed: \(detail)"
        case .httpError(let code): "Model download HTTP \(code)"
        case .sizeMismatch(let expected, let actual):
            "Model size mismatch (expected \(expected), got \(actual))"
        case .checksumMismatch: "Model checksum mismatch — retry the download"
        case .noPackageInArchive: "Model archive has no .mlpackage"
        }
    }
}
