import AmgiIcons
import AmgiUI
import AnkiBackend
import Dependencies
import Foundation

/// Deck-icon persistence, backed by Anki's **collection config** (`col.conf`)
/// under two namespaced keys — this is the Anki-sanctioned home for
/// app-specific data that must ride along with normal collection sync, so
/// every device syncing the same collection sees the same icons:
///
/// - `"amgi.deckIcons"` — **manual picks** (`deckId → Phosphor case name`).
///   User intent; never auto-overwritten. "Automatic" in the picker clears
///   it, falling back to the recorded auto pick.
/// - `"amgi.deckIconsAuto"` — **auto picks** (`deckId → {icon, name}`).
///   First writer prevails: a device resolving a deck nobody has picked yet
///   records its suggestion, and every other device adopts it instead of
///   deriving its own. Entries carry the deck name they were picked for, so
///   a rename re-resolves exactly once ("first pick for the current name").
///
/// Absence of both entries means the icon is computed on demand (and then
/// recorded). Reads go through in-memory mirrors kept fresh by `refresh()`;
/// screens call it on every generation-keyed reload, and all writers bump
/// the generation (via `CollectionStore`), so renders never see stale data.
///
/// Clobber-window note: `col.conf` is a single blob synced last-write-wins,
/// so every write is a *fresh* fetch → patch → immediate write (never a
/// blind put of the mirrors). Two devices recording picks for *different*
/// decks in the same offline window can still lose one edit at the blob
/// level — accepted as low-stakes for icons; the per-deck "first prevails"
/// check inside the fetched blob keeps the common case correct.
@MainActor
package enum DeckIconOverrides {
    static let configKey = "amgi.deckIcons"
    static let autoConfigKey = "amgi.deckIconsAuto"

    /// Mirrors of the conf blobs for synchronous render paths.
    private static var mirror: [Int64: String] = [:]
    private static var autoMirror: [Int64: AutoEntry] = [:]

    struct AutoEntry: Codable, Equatable {
        var icon: String
        /// Deck name the pick was made for — a mismatch means the deck was
        /// renamed and the pick should re-resolve once.
        var name: String
    }

    // MARK: - Reads

    /// Synchronous manual-pick lookup against the mirror. Call `refresh()`
    /// first when correctness across generations matters (every screen load
    /// does).
    static func iconName(for deckId: Int64) -> String? {
        mirror[deckId]
    }

    static func all() -> [Int64: String] {
        mirror
    }

    /// Synchronous best-effort icon for first paint: manual override, else
    /// a synced auto pick made for the current name. Never touches the
    /// model — refine passes fill in whatever this returns nil for.
    package static func initialIcon(deckId: Int64, name: String, fullName: String? = nil) -> String? {
        if let manual = iconName(for: deckId) { return manual }
        guard !DeckIconRendering.hasLeadingEmoji(in: name) else { return nil }
        if let entry = autoMirror[deckId], entry.name == name {
            return entry.icon
        }
        return nil
    }

    /// Re-pulls both blobs from the collection config into the mirrors.
    /// Two cheap RPCs; safe to call on every screen load.
    package static func refresh() async {
        @Dependency(\.ankiBackend) var backend
        let manual: [Int64: String]? = try? backend.getConfigJSONValue(for: configKey)
        mirror = manual ?? [:]
        let auto: [Int64: AutoEntry]? = try? backend.getConfigJSONValue(for: autoConfigKey)
        autoMirror = auto ?? [:]
        migrateLegacyLocalCache()
    }

    /// One-time cleanup: the pre-sync local suggestion cache
    /// (`amgi_deck_icon_suggestions_v1`) is superseded by the synced auto
    /// blob; entries re-resolve once per deck and are then recorded there.
    private static func migrateLegacyLocalCache() {
        UserDefaults.standard.removeObject(forKey: "amgi_deck_icon_suggestions_v1")
    }

    // MARK: - Writes

    /// Persists a manual pick (or clears it with `nil`) using
    /// fetch → patch → write against a freshly pulled blob.
    static func set(_ iconName: String?, for deckId: Int64) async {
        @Dependency(\.ankiBackend) var backend
        let stored: [Int64: String]? = try? backend.getConfigJSONValue(for: configKey)
        var updated = stored ?? [:]
        if let iconName {
            updated[deckId] = iconName
        } else {
            updated.removeValue(forKey: deckId)
        }
        do {
            try backend.setConfigJSONValue(updated, for: configKey)
            mirror = updated
        } catch {
            print("[DeckIconOverrides] Failed to persist icons: \(error)")
        }
    }

    /// Records an auto pick — first writer prevails. If another device
    /// already picked for this deck (at the same name), its choice wins and
    /// ours is discarded; otherwise the fresh blob is patched and written.
    private static func recordAutoPick(deckId: Int64, name: String, icon: String) async -> String {
        @Dependency(\.ankiBackend) var backend
        let stored: [Int64: AutoEntry]? = try? backend.getConfigJSONValue(for: autoConfigKey)
        var updated = stored ?? [:]
        if let existing = updated[deckId], existing.name == name {
            // Somebody picked first — adopt their choice.
            autoMirror[deckId] = existing
            return existing.icon
        }
        updated[deckId] = AutoEntry(icon: icon, name: name)
        do {
            try backend.setConfigJSONValue(updated, for: autoConfigKey)
            autoMirror = updated
        } catch {
            print("[DeckIconOverrides] Failed to record auto pick: \(error)")
        }
        return icon
    }

    // MARK: - Resolution

    /// The render-time icon for a deck, in precedence order:
    /// manual override → synced auto pick (current name) → compute once and
    /// record (first-to-pick prevails across devices). Emoji-prefixed names
    /// keep the legacy tile unless manually overridden.
    package static func resolvedIcon(
        deckId: Int64,
        name: String,
        fullName: String? = nil
    ) async -> String? {
        if let manual = iconName(for: deckId) { return manual }
        guard !DeckIconRendering.hasLeadingEmoji(in: name) else { return nil }
        if let entry = autoMirror[deckId], entry.name == name {
            return entry.icon
        }
        let semanticSource = fullName ?? name
        let path = semanticSource.replacingOccurrences(of: "::", with: " ")
        let suggested = await IconSuggester.shared.bestMatch(for: path)
        return await recordAutoPick(deckId: deckId, name: name, icon: suggested)
    }
}
