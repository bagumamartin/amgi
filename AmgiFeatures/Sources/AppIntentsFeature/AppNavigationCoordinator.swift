public import AmgiAppCore
public import Foundation
public import Observation

public enum AppNavigationRoute: Codable, Hashable, Sendable {
    case review(deckID: Int64)
    case browse(query: String)
    case browseDeck(deckID: Int64)
    case openNote(noteID: Int64)
    case studyAssistant(prompt: String)
    case presentSync
}

public struct AppNavigationRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let profile: ProfileContext
    public let route: AppNavigationRoute

    /// A decoded request cannot carry a meaningful in-process selection epoch.
    /// Its persisted stable profile ID is still valid, but a fresh process must
    /// not reject a request merely because its runtime-only epoch was replaced.
    fileprivate let profileWasRebound: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        expiresAt: Date = .now.addingTimeInterval(5 * 60),
        profile: ProfileContext,
        route: AppNavigationRoute
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.profile = profile
        self.route = route
        self.profileWasRebound = false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case expiresAt
        case profileID
        case profileDisplayName
        case profile
        case route
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        route = try container.decode(AppNavigationRoute.self, forKey: .route)

        let profileID: String
        let profileDisplayName: String
        if let storedID = try? container.decode(String.self, forKey: .profileID),
           let storedName = try? container.decode(String.self, forKey: .profileDisplayName) {
            profileID = storedID
            profileDisplayName = storedName
        } else {
            // Accept requests written by the first implementation, which
            // encoded the complete runtime context. The old selection epoch
            // is intentionally discarded after decoding.
            let legacyProfile = try container.decode(ProfileContext.self, forKey: .profile)
            profileID = legacyProfile.id
            profileDisplayName = legacyProfile.displayName
        }

        profile = ProfileContext(
            id: profileID,
            displayName: profileDisplayName,
            selectionID: UUID()
        )
        profileWasRebound = true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(profile.id, forKey: .profileID)
        try container.encode(profile.displayName, forKey: .profileDisplayName)
        try container.encode(route, forKey: .route)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.createdAt == rhs.createdAt
            && lhs.expiresAt == rhs.expiresAt
            && lhs.profile == rhs.profile
            && lhs.route == rhs.route
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(createdAt)
        hasher.combine(expiresAt)
        hasher.combine(profile)
        hasher.combine(route)
    }

    public var isExpired: Bool { expiresAt <= .now }
}

/// Durable, profile-fenced handoff between an App Intent and the SwiftUI root.
///
/// Requests are persisted in the App Group so they survive the short interval
/// between intent execution and scene activation. A request is consumed only
/// while the exact profile activation that created it is still current.
@MainActor
@Observable
public final class AppNavigationCoordinator {
    public static let shared = AppNavigationCoordinator()

    public private(set) var requestID: UUID?
    public private(set) var pendingCount = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var queue: [AppNavigationRequest]

    public init(
        defaults: UserDefaults = AppGroup.defaults,
        storageKey: String = "automation.navigation.pending.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.queue = Self.loadQueue(from: defaults, key: storageKey)
        self.queue.removeAll { $0.isExpired }
        self.requestID = queue.last?.id
        self.pendingCount = queue.count
        persist()
    }

    @discardableResult
    public func submit(_ route: AppNavigationRoute) -> AppNavigationRequest {
        submit(route, profile: AccountStore.shared.selectedContext)
    }

    @discardableResult
    public func submit(
        _ route: AppNavigationRoute,
        profile: ProfileContext
    ) -> AppNavigationRequest {
        prune()
        let request = AppNavigationRequest(profile: profile, route: route)
        queue.append(request)
        if queue.count > 8 {
            queue.removeFirst(queue.count - 8)
        }
        requestID = request.id
        pendingCount = queue.count
        persist()
        return request
    }

    public func consume() -> AppNavigationRequest? {
        prune()
        let currentProfile = AccountStore.shared.selectedContext

        // Discard stale profile activations in the same consumption pass. If
        // a current request followed a stale one, returning immediately after
        // the stale request would leave the current request parked without an
        // observable requestID change.
        while let request = queue.first {
            queue.removeFirst()
            requestID = queue.last?.id
            pendingCount = queue.count
            persist()
            let isCurrent = request.profileWasRebound
                ? request.profile.id == currentProfile.id
                : request.profile.isCurrent(currentProfile)
            guard isCurrent else { continue }
            if request.profileWasRebound {
                return AppNavigationRequest(
                    id: request.id,
                    createdAt: request.createdAt,
                    expiresAt: request.expiresAt,
                    profile: currentProfile,
                    route: request.route
                )
            }
            return request
        }

        requestID = nil
        pendingCount = 0
        persist()
        return nil
    }

    public func discardPending() {
        queue.removeAll()
        requestID = nil
        pendingCount = 0
        defaults.removeObject(forKey: storageKey)
    }

    private func prune() {
        queue.removeAll { $0.isExpired }
        pendingCount = queue.count
    }

    private func persist() {
        if queue.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func loadQueue(
        from defaults: UserDefaults,
        key: String
    ) -> [AppNavigationRequest] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AppNavigationRequest].self, from: data)
        else { return [] }
        return decoded
    }
}
