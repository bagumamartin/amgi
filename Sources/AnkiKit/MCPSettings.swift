public import Foundation

/// Capability tier for the MCP server, mirrored from the app's Settings
/// pane. Tools declare the minimum tier they require; the server only
/// registers tools whose requirement is satisfied, so agents can't even
/// see mutations that are disabled.
public enum ToolTier: String, Codable, Sendable, Comparable {
    case readOnly
    case safeWrite
    case full

    private var rank: Int {
        switch self {
        case .readOnly: return 0
        case .safeWrite: return 1
        case .full: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Persisted MCP configuration. Written by the app's Settings pane,
/// read by the `amgi-mcp` helper at startup. Lives at
/// `<collectionRoot>/mcp.json` — a plain file rather than
/// UserDefaults because it must be readable cross-process without
/// CFPreferences cache staleness, and it doubles as the seam for a
/// future sandboxed build (app-group container).
public struct MCPSettings: Codable, Sendable {
    /// Master switch. The helper refuses to start when false.
    public var enabled: Bool
    /// Highest capability tier exposed to connected clients.
    public var tier: ToolTier
    /// When true, mutating tools fail while Amgi.app is running.
    public var blockWritesWhileAppRunning: Bool
    /// Snapshot `collection.anki2` before destructive operations.
    public var snapshotsBeforeDestructive: Bool
    /// Profile exposed over MCP. nil = follow the app's active profile
    /// (`amgi.selectedUser` in standard UserDefaults).
    public var profileID: String?

    public static let `default` = Self(
        enabled: true,
        tier: .safeWrite,
        blockWritesWhileAppRunning: false,
        snapshotsBeforeDestructive: true,
        profileID: nil
    )

    public enum CodingKeys: String, CodingKey {
        case enabled
        case tier
        case blockWritesWhileAppRunning = "blockWritesWhileAppRunning"
        case snapshotsBeforeDestructive = "snapshotsBeforeDestructive"
        case profileID = "profileId"
    }

    init(
        enabled: Bool,
        tier: ToolTier,
        blockWritesWhileAppRunning: Bool,
        snapshotsBeforeDestructive: Bool,
        profileID: String?
    ) {
        self.enabled = enabled
        self.tier = tier
        self.blockWritesWhileAppRunning = blockWritesWhileAppRunning
        self.snapshotsBeforeDestructive = snapshotsBeforeDestructive
        self.profileID = profileID
    }

    /// Loads settings from `path`, falling back to defaults for missing
    /// fields so new options don't invalidate existing config files.
    public static func load(from path: String) -> Self {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("amgi-mcp: malformed \(path) (\(error)); using defaults\n".utf8)
            )
            return .default
        }
    }
}

/// Resolved runtime locations for one profile's collection.
public struct CollectionPaths: Sendable {
    public let profileID: String
    public let directory: URL
    public let collectionPath: String
    public let mediaFolderPath: String
    public let mediaDbPath: String

    public static func resolve(
        preferredProfile: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let profileID = preferredProfile
            ?? environment["AMGI_PROFILE"]
            ?? UserDefaults.standard.string(forKey: "amgi.selectedUser")
            ?? "default"
        let dir = CollectionLayout.profileDirectory(for: profileID, environment: environment)
        return Self(
            profileID: profileID,
            directory: dir,
            collectionPath: CollectionLayout.collectionPath(for: profileID, environment: environment),
            mediaFolderPath: CollectionLayout.mediaFolderPath(for: profileID, environment: environment),
            mediaDbPath: CollectionLayout.mediaDbPath(for: profileID, environment: environment)
        )
    }
}
