import AnkiBackend
import AnkiProtoBridge
import AnkiSync
public import AnkiKit
public import Dependencies
import DependenciesMacros
import Foundation
import Logging

private let logger = Logger(label: "\(Bundle.main.bundleIdentifier ?? "app").sync.service")

@DependencyClient
public struct SyncService: Sendable {
    public var sync: @Sendable (_ endpoint: String, _ hostKey: String) async throws -> SyncSummary
    public var fullSync: @Sendable (_ endpoint: String, _ hostKey: String, _ direction: SyncDirection) async throws -> Void
    public var syncMedia: @Sendable (_ endpoint: String, _ hostKey: String) async throws -> Void
    public var login: @Sendable (_ endpoint: String, _ username: String, _ password: String) async throws -> String
}

extension SyncService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            sync: { endpoint, hostKey in
                var auth = SyncAuth(hkey: hostKey, endpoint: endpoint)

                do {
                    // Awaited on purpose: the async invoke overload detaches
                    // the blocking FFI call off the caller's actor. These
                    // closures are awaited from MainActor (SyncCoordinator,
                    // SyncSheet), and with NonisolatedNonsendingByDefault the
                    // closure body itself runs there — a synchronous invoke
                    // would freeze the UI for the whole network sync.
                    let result = try await backend.invoke(.syncCollection(auth: auth, syncMedia: true))
                    logger.info("SyncCollection: required=\(result.required), message='\(result.serverMessage)'")

                    if let newEndpoint = result.newEndpoint {
                        auth = SyncAuth(hkey: auth.hkey, endpoint: newEndpoint)
                        // AnkiWeb pins upload/download to a specific shard and
                        // only emits the redirect here — persist it so later
                        // FullUploadOrDownload calls hit the shard directly.
                        try? KeychainHelper.saveCurrentEndpoint(newEndpoint)
                    }

                    switch result.required {
                    case .noChanges, .normalSync:
                        return SyncSummary()

                    case .fullSync:
                        logger.info("Full sync required - user must choose direction")
                        throw SyncError.fullSyncRequired

                    case .fullDownload:
                        logger.info("Full download required (local collection empty)")
                        try await backend.invoke(.fullUploadOrDownload(
                            auth: auth, upload: false, serverUsn: result.serverMediaUsn
                        ))
                        // CheckDatabase scans the whole collection after a
                        // fresh download — detach it like the sync above.
                        let backendForCheck = backend
                        try? await Task.detached(priority: .userInitiated) {
                            try backendForCheck.checkDatabase()
                        }.value
                        return SyncSummary()

                    case .fullUpload:
                        logger.info("Full upload required")
                        try await backend.invoke(.fullUploadOrDownload(
                            auth: auth, upload: true, serverUsn: result.serverMediaUsn
                        ))
                        return SyncSummary()

                    case .unrecognized(let v):
                        logger.warning("Unrecognized sync required: \(v)")
                        return SyncSummary()
                    }
                } catch let error as BackendError {
                    logger.error("Sync error: \(error.message)")
                    if error.isSyncAuthError { throw SyncError.authFailed }
                    throw SyncError(message: error.message)
                }
            },
            fullSync: { endpoint, hostKey, direction in
                let auth = SyncAuth(hkey: hostKey, endpoint: endpoint)
                do {
                    try await backend.invoke(.fullUploadOrDownload(
                        auth: auth, upload: direction == .upload, serverUsn: 0
                    ))
                } catch let error as BackendError {
                    if error.isSyncAuthError { throw SyncError.authFailed }
                    throw SyncError(message: error.message)
                }
            },
            syncMedia: { endpoint, hostKey in
                let auth = SyncAuth(hkey: hostKey, endpoint: endpoint)
                do {
                    try await backend.invoke(.syncMedia(auth: auth))
                } catch let error as BackendError {
                    if error.isSyncAuthError { throw SyncError.authFailed }
                    throw SyncError(message: error.message)
                }
            },
            login: { endpoint, username, password in
                do {
                    let hkey = try await backend.invoke(.syncLogin(
                        endpoint: endpoint, username: username, password: password
                    ))
                    logger.info("Login successful for \(username)")
                    return hkey
                } catch let error as BackendError {
                    logger.error("Login failed: \(error.message)")
                    throw SyncError.authFailed
                }
            }
        )
    }()
}

extension SyncService: TestDependencyKey {
    public static let testValue = SyncService()
}

extension DependencyValues {
    public var syncService: SyncService {
        get { self[SyncService.self] }
        set { self[SyncService.self] = newValue }
    }
}
