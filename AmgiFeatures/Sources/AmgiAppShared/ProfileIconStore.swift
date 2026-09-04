import AnkiBackend
import Dependencies
import Foundation
import Observation

/// Per-profile emoji icons, persisted in the **active collection's config**
/// (`col.conf`) under `"amgi.profileIcons"`: `{profileId: emoji}`.
///
/// Why the active collection hosts the map: each profile owns an isolated
/// collection, and `col.conf` is only readable for the open one. The map
/// rides whichever collection is open, so an icon edited under profile X
/// syncs with X's collection to every device that also uses X. Entries for
/// profiles unknown to a device are harmless ballast.
///
/// Same write discipline as deck icons: fetch → patch → write against a
/// freshly pulled blob (`col.conf` syncs last-write-wins at the blob level).
@MainActor
@Observable
package final class ProfileIconStore {
    package static let shared = ProfileIconStore()
    static let configKey = "amgi.profileIcons"

    package private(set) var icons: [String: String] = [:]

    private init() {}

    /// Emoji for a profile, or nil ⇒ render the default glyph.
    package func icon(for profileID: String) -> String? {
        icons[profileID]
    }

    /// Re-pulls the blob into the mirror. One cheap RPC; call on screen load.
    package func refresh() async {
        @Dependency(\.ankiBackend) var backend
        let stored: [String: String]? = try? backend.getConfigJSONValue(for: Self.configKey)
        icons = stored ?? [:]
    }

    /// Persists an emoji (or clears it back to the default with `nil`) using
    /// fetch → patch → write against a freshly pulled blob.
    package func set(_ emoji: String?, for profileID: String) async {
        @Dependency(\.ankiBackend) var backend
        let stored: [String: String]? = try? backend.getConfigJSONValue(for: Self.configKey)
        var updated = stored ?? [:]
        if let emoji {
            updated[profileID] = emoji
        } else {
            updated.removeValue(forKey: profileID)
        }
        do {
            try backend.setConfigJSONValue(updated, for: Self.configKey)
            icons = updated
        } catch {
            print("[ProfileIconStore] Failed to persist profile icon: \(error)")
        }
    }

    /// Accepts `text` only when it begins with an emoji-presentation
    /// character (skin-tone/ZWJ sequences collapse to their first grapheme).
    package static func sanitizedEmoji(from text: String) -> String? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first,
              let scalar = first.unicodeScalars.first,
              scalar.properties.isEmoji
        else { return nil }
        return String(first)
    }
}
