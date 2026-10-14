import CryptoKit
import Foundation

/// Modular, pinned MLX assets. Receipts publish only after SHA-256 validation.
public actor ModelAssetManager {
    public static let shared = ModelAssetManager()
    public enum Module: String, Codable, CaseIterable, Sendable {
        case text = "text-q8", vision = "vision-q8", audio = "audio-bf16"
    }
    public enum Status: Sendable, Equatable {
        case unknown, notInstalled
        case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64?)
        case verifying, extracting, compiling
        case ready(Int), failed(String)
    }
    public struct ManifestInfo: Sendable, Equatable { public var version: Int; public var byteSize: Int64 }
    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable { let bytes: Int64; let sha256: String }
        let files: [String: File]
    }
    public static let revision = "06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd"
    public static let modelIdentity = "embeddinggemma2:\(revision):text-q8:vision-q8:audio-bf16:768:preprocessing-v3"
    public let manifestURL: URL
    private let baseURL: URL
    public init(manifestURL: URL = URL(string: "https://huggingface.co/Nurymanau/EmbeddingGemma-2-MLX-Swift/resolve/\(ModelAssetManager.revision)/manifest.json")!) {
        self.manifestURL = manifestURL; baseURL = manifestURL.deletingLastPathComponent()
    }
    public private(set) var status: Status = .unknown
    private var observers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var activeTask: URLSessionDownloadTask?
    private var activeResumeURL: URL?
    private var inFlight = false
    private var userCancelled = false
    public func observe() -> AsyncStream<Status> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(status)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func setStatus(_ value: Status) {
        status = value
        for observer in observers.values { observer.yield(value) }
        switch value {
        case .ready, .failed, .notInstalled: NotificationCenter.default.post(name: .amgiModelAssetChanged, object: nil)
        default: break
        }
    }
    public nonisolated(unsafe) static var modelsRootOverride: URL?
    public nonisolated static var modelsRootURL: URL {
        if let modelsRootOverride { return modelsRootOverride }
        let support = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.bagumamartin.ijuka")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AmgiEmbeddings/models/Gemma2-\(revision)", isDirectory: true)
    }

    /// Removes only the previous E5 model's known install and partial-download
    /// artifacts. Gemma assets, retrieval indexes, and unrelated files remain
    /// untouched. Called at app startup so cleanup does not depend on opting in
    /// to the new model download.
    public nonisolated static func removeLegacyE5Assets() {
        guard modelsRootOverride == nil else { return }
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyGroupIDs = [
            "group.com.bagumamartin.AmgiApp",
            "39557WW39R.group.com.bagumamartin.AmgiApp",
            "group.com.amgiapp",
        ]
        var roots = [
            applicationSupport.appendingPathComponent("AmgiEmbeddings/models", isDirectory: true),
            applicationSupport.appendingPathComponent("AmgiIcons/models", isDirectory: true),
        ]
        for groupID in ["group.com.bagumamartin.ijuka"] + legacyGroupIDs {
            guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { continue }
            roots.append(container.appendingPathComponent("AmgiEmbeddings/models", isDirectory: true))
        }

        for root in Set(roots) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                if name.range(of: #"^\.staging-v[0-9]+$"#, options: .regularExpression) != nil {
                    try? fileManager.removeItem(at: entry)
                    continue
                }
                if name.range(of: #"^\.resume-v[0-9]+\.dat$"#, options: .regularExpression) != nil {
                    try? fileManager.removeItem(at: entry)
                    continue
                }
                guard name.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil else { continue }
                let model = entry.appendingPathComponent("MultilingualE5Small.mlmodelc", isDirectory: true)
                guard fileManager.fileExists(atPath: model.path) else { continue }
                try? fileManager.removeItem(at: model)
                try? fileManager.removeItem(at: entry.appendingPathComponent("receipt.json"))
                if (try? fileManager.contentsOfDirectory(atPath: entry.path).isEmpty) == true {
                    try? fileManager.removeItem(at: entry)
                }
            }
        }
    }

    public nonisolated static func directory(for module: Module) -> URL { modelsRootURL.appendingPathComponent(module.rawValue, isDirectory: true) }
    public nonisolated static func isInstalled(_ module: Module) -> Bool {
        let dir = directory(for: module)
        guard let receipt = try? String(contentsOf: dir.appendingPathComponent(".verified"), encoding: .utf8), receipt == modelIdentity,
              let manifest = try? bundledManifest() else { return false }
        return manifest.files.filter { $0.key.hasPrefix(module.rawValue + "/") }.allSatisfy { path, file in
            (try? modelsRootURL.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes)
        }
    }
    public nonisolated static var isModelInstalled: Bool { isInstalled(.text) }
    public nonisolated static func installedVersion() -> Int? { isModelInstalled ? 2 : nil }
    public nonisolated static func installedSizeBytes() -> Int64? {
        guard isModelInstalled, let manifest = try? bundledManifest() else { return nil }
        return manifest.files.filter { path, _ in Module.allCases.contains { path.hasPrefix($0.rawValue + "/") && isInstalled($0) } }.values.reduce(0) { $0 + $1.bytes }
    }
    nonisolated static func bundledManifest() throws -> Manifest {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Gemma2") else { throw ModelAssetError.badManifest("Missing pinned manifest") }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    public nonisolated static func downloadSize(for module: Module) -> Int64 {
        (try? bundledManifest().files.filter { $0.key.hasPrefix(module.rawValue + "/") }.values.reduce(Int64(0)) { $0 + $1.bytes }) ?? 0
    }
    public func loadRemoteManifest() throws -> ManifestInfo {
        let manifest = try Self.bundledManifest()
        return ManifestInfo(version: 2, byteSize: manifest.files.filter { $0.key.hasPrefix("text-q8/") }.values.reduce(0) { $0 + $1.bytes })
    }
    /// Caller must obtain explicit module consent. Automatic retries honor its network policy.
    public func ensureModelAvailable(allowExpensiveNetwork: Bool = false) async { await install(.text, allowExpensiveNetwork: allowExpensiveNetwork) }
    public func install(_ module: Module, allowExpensiveNetwork: Bool = false) async {
        guard !inFlight else { return }
        if Self.isInstalled(module) { setStatus(.ready(2)); return }
        inFlight = true; userCancelled = false
        defer { inFlight = false; activeTask = nil; activeResumeURL = nil }
        do {
            let manifest = try Self.bundledManifest()
            let files = manifest.files.filter { $0.key.hasPrefix(module.rawValue + "/") }.sorted { $0.key < $1.key }
            guard !files.isEmpty else { throw ModelAssetError.badManifest("Empty module") }
            let total = files.reduce(Int64(0)) { $0 + $1.value.bytes }
            let staging = Self.modelsRootURL.appendingPathComponent(".staging-\(module.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var excluded = Self.modelsRootURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
            var complete: Int64 = 0
            for (path, file) in files {
                guard !userCancelled else { throw CancellationError() }; try Task.checkCancellation()
                let name = URL(fileURLWithPath: path).lastPathComponent
                let destination = staging.appendingPathComponent(name)
                if (try? Self.verify(destination, file: file)) == nil {
                    activeResumeURL = staging.appendingPathComponent(name + ".resume")
                    let previous = complete
                    setStatus(.downloading(fraction: Double(complete) / Double(total), receivedBytes: complete, totalBytes: total))
                    try await download(baseURL.appendingPathComponent(path), destination: destination, allowExpensive: allowExpensiveNetwork, progress: { [weak self] bytes in
                        Task { await self?.progress(received: previous + bytes, total: total) }
                    })
                    setStatus(.verifying); try Self.verify(destination, file: file)
                    if let activeResumeURL { try? FileManager.default.removeItem(at: activeResumeURL) }
                }
                complete += file.bytes
            }
            guard !userCancelled else { throw CancellationError() }
            try Self.modelIdentity.write(to: staging.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
            let destination = Self.directory(for: module)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
            await TextEmbedder.shared.resetEngineForModelInstall(); setStatus(.ready(2))
        } catch { setStatus(userCancelled || error is CancellationError ? .notInstalled : .failed(error.localizedDescription)) }
    }
    nonisolated static func verify(_ url: URL, file: Manifest.File) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard Int64(size) == file.bytes else { throw ModelAssetError.sizeMismatch(expected: file.bytes, actual: Int64(size)) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw ModelAssetError.checksumMismatch }
    }
    private func progress(received: Int64, total: Int64) {
        guard case .downloading = status else { return }
        setStatus(.downloading(fraction: min(1, Double(received) / Double(total)), receivedBytes: received, totalBytes: total))
    }
    private func download(_ url: URL, destination: URL, allowExpensive: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = allowExpensive; config.allowsConstrainedNetworkAccess = false
        let delegate = ModelDownloadDelegate(destination: destination) { received, _ in progress(received) }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let resume = activeResumeURL.flatMap { try? Data(contentsOf: $0) }
        let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        activeTask = task
        do {
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                    delegate.continuation = continuation; delegate.task = task; task.resume()
                }
            } onCancel: { task.cancel() }
        } catch {
            if !userCancelled, let activeResumeURL { try? FileManager.default.removeItem(at: activeResumeURL) }
            throw error
        }
    }
    public func cancelDownload() {
        userCancelled = true
        let resumeURL = activeResumeURL
        activeTask?.cancel { data in if let data, let resumeURL { try? data.write(to: resumeURL, options: .atomic) } }
    }
    public func removeInstalledModel() async throws {
        guard !inFlight else { cancelDownload(); throw ModelAssetError.downloadFailed("Wait for the download to stop before removing models") }
        await TextEmbedder.shared.resetEngineForModelInstall()
        if FileManager.default.fileExists(atPath: Self.modelsRootURL.path) { try FileManager.default.removeItem(at: Self.modelsRootURL) }
        setStatus(.notInstalled)
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
