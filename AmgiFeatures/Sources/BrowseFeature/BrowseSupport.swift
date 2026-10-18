import AmgiEmbeddings
// AmgiApp/Sources/Browse/BrowseSupport.swift
//
// NOTE: deliberately no `import AmgiIcons` here. Under this project's
// explicit-module build certain NEW-file/plan combos report the local SPM
// package as unresolvable from brand-new source files while long-standing
// importers compile fine (Xcode 26.5 driver quirk hit 2026-08). The embed
// calls therefore go through `NoteEmbedderBridge` in Shared/, whose file
// resolves the package reliably.
import AnkiBackend
import AnkiClients
import AnkiKit
import AmgiAppCore
import AmgiAppShared
import Dependencies
import Foundation
import SwiftUI

/// Anki's field checksum primitive: 64-bit FNV-1a over UTF-8 bytes.
/// Shared by the note editor (csum) and the semantic index (staleness).
enum BrowseFnv {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: - Saved searches (spec §6)

/// Persists named queries in the ACTIVE COLLECTION's config under the same
/// key desktop Anki uses (`savedFilters`) — so saved searches SYNC cross-
/// device AND round-trip with desktop. Whole-blob last-write-wins applies,
/// matching how desktop itself stores them; writes follow the deck-icon
/// precedent (fetch fresh → patch → write).
@MainActor
@Observable
final class SavedSearchStore {
    /// Desktop-compatible key.
    static let configKey = "savedFilters"

    struct SavedSearch: Identifiable, Equatable {
        let name: String
        let query: String
        var id: String { name }
    }

    private(set) var searches: [SavedSearch] = []

    @ObservationIgnored @Dependency(\.ankiBackend) private var backend
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    func refresh() {
        let stored: [String: String]? = try? backend.getConfigJSONValue(for: Self.configKey)
        searches = stored?
            .map { SavedSearch(name: $0.key, query: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() } ?? []
    }

    /// Saves under `name`, overwriting an existing entry with the same name
    /// (desktop asks before overwrite; the save-as UI enforces uniqueness
    /// up front instead — fewer dialogs on touch screens).
    func save(name: String, query: String) {
        guard !name.isEmpty else { return }
        var stored: [String: String] =
            (try? backend.getConfigJSONValue(for: Self.configKey)) ?? [:]
        stored[name] = query
        do {
            try backend.setConfigJSONValue(stored, for: Self.configKey)
            collectionStore.markLocalMutation()
        } catch {
            return
        }
        refresh()
    }

    func delete(name: String) {
        var stored: [String: String] =
            (try? backend.getConfigJSONValue(for: Self.configKey)) ?? [:]
        stored.removeValue(forKey: name)
        do {
            try backend.setConfigJSONValue(stored, for: Self.configKey)
            collectionStore.markLocalMutation()
        } catch {
            return
        }
        refresh()
    }

    func rename(from oldName: String, to newName: String) {
        guard let existing = searches.first(where: { $0.name == oldName }) else { return }
        delete(name: oldName)
        save(name: newName, query: existing.query)
    }
}

// MARK: - Flag labels (desktop `flagLabels` collection config)

/// Custom flag labels, stored under the same `flagLabels` config key
/// desktop uses (`{"1": "My label", …}`). Absent keys fall back to the
/// stock color names.
@MainActor
@Observable
final class FlagLabelStore {
    static let configKey = "flagLabels"
    static let defaults = ["1": "Red", "2": "Orange", "3": "Green", "4": "Blue", "5": "Pink", "6": "Turquoise", "7": "Purple"]

    private(set) var labels: [String: String] = defaults

    @ObservationIgnored @Dependency(\.ankiBackend) private var backend
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    func refresh() {
        let stored: [String: String]? = try? backend.getConfigJSONValue(for: Self.configKey)
        var merged = Self.defaults
        if let stored {
            for (k, v) in stored where !v.isEmpty { merged[k] = v }
        }
        labels = merged
    }

    func label(for flag: UInt32) -> String {
        labels[String(flag)] ?? Self.defaults[String(flag)] ?? "Flag \(flag)"
    }

    func rename(flag: UInt32, to name: String) {
        var stored: [String: String] =
            (try? backend.getConfigJSONValue(for: Self.configKey)) ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaults[String(flag)] {
            stored.removeValue(forKey: String(flag))
        } else {
            stored[String(flag)] = trimmed
        }
        do {
            try backend.setConfigJSONValue(stored, for: Self.configKey)
            collectionStore.markLocalMutation()
        } catch {
            return
        }
        refresh()
    }

    func reset(flag: UInt32) {
        rename(flag: flag, to: Self.defaults[String(flag)] ?? "")
    }
}

// MARK: - Sidebar filter sections

/// One tappable sidebar filter entry.
struct FilterNode: Identifiable, Equatable {
    enum Composition: Equatable {
        /// Tapping replaces the whole query (plain click semantics).
        case replace
        /// Long-press/menu alternatives mirroring desktop modifiers.
        case andWithExisting
        case orWithExisting
        case negateAndAdd
    }

    let title: String
    let systemImage: String
    /// Grammar fragment this node contributes (already quoted where needed).
    let fragment: String
    let role: Role?

    enum Role: Equatable { case state(BrowseModelStateColor), flag(UInt32) }

    var id: String { title + "#" + fragment }

    init(title: String, systemImage: String, fragment: String, role: Role?) {
        self.title = title
        self.systemImage = systemImage
        self.fragment = fragment
        self.role = role
    }
}

enum BrowseModelStateColor: Hashable {
    case newState, learning, review, suspended, buried

    var searchFragment: String {
        switch self {
        case .newState: "is:new"
        case .learning: "is:learn"
        case .review: "is:review"
        case .suspended: "is:suspended"
        case .buried: "is:buried"
        }
    }

    var title: String {
        switch self {
        case .newState: "New"
        case .learning: "Learning"
        case .review: "Review"
        case .suspended: "Suspended"
        case .buried: "Buried"
        }
    }
}

/// Static sidebar sections mirroring desktop Anki's sidebar stages.
///
/// Fragments are canonical engine grammar (rslib parser.rs / writer.rs):
/// `prop:due=0` for due-today, numeric `flag:0…7`, `tag:none` for untagged.
/// Never use `due:today`, named `flag:red`, `-flag:any`, or `-tag:*`
/// (`tag:*` matches every note, so its negation is wrong).
enum BrowseFilterSections {
    static func today() -> [FilterNode] {
        [
            (L10n.text("Due today"), "clock.badge.checkmark", "prop:due=0"),
            (L10n.text("Added today"), "plus.circle", "added:1"),
            (L10n.text("Edited today"), "pencil", "edited:1"),
            (L10n.text("Studied today"), "checkmark.seal", "rated:1"),
            (L10n.text("First review"), "flag.checkered", "introduced:1"),
            (L10n.text("Again today"), "arrow.uturn.backward", "rated:1:1"),
            (L10n.text("Rescheduled today"), "arrow.triangle.2.circlepath", "resched:1"),
            (L10n.text("Overdue"), "exclamationmark.triangle", "is:due -prop:due=0"),
        ]
        .map { FilterNode(title: $0.0, systemImage: $0.1, fragment: $0.2, role: nil) }
    }

    static func cardStates() -> [FilterNode] {
        [
            FilterNode(title: L10n.text("New"), systemImage: "circle", fragment: "is:new",
                       role: .state(.newState)),
            FilterNode(title: L10n.text("Learning"), systemImage: "circle.fill", fragment: "is:learn",
                       role: .state(.learning)),
            FilterNode(title: L10n.text("Review"), systemImage: "circle.circle", fragment: "is:review",
                       role: .state(.review)),
            FilterNode(title: L10n.text("Suspended"), systemImage: "pause.circle", fragment: "is:suspended",
                       role: .state(.suspended)),
            FilterNode(title: L10n.text("Buried"), systemImage: "archivebox", fragment: "is:buried",
                       role: .state(.buried)),
        ]
    }

    static func flags() -> [FilterNode] {
        [
            FilterNode(title: L10n.text("No flag"), systemImage: "flag.slash", fragment: "flag:0", role: nil),
            FilterNode(title: L10n.text("Red"), systemImage: "flag.fill", fragment: "flag:1", role: .flag(1)),
            FilterNode(title: L10n.text("Orange"), systemImage: "flag.fill", fragment: "flag:2", role: .flag(2)),
            FilterNode(title: L10n.text("Green"), systemImage: "flag.fill", fragment: "flag:3", role: .flag(3)),
            FilterNode(title: L10n.text("Blue"), systemImage: "flag.fill", fragment: "flag:4", role: .flag(4)),
            FilterNode(title: L10n.text("Pink"), systemImage: "flag.fill", fragment: "flag:5", role: .flag(5)),
            FilterNode(title: L10n.text("Turquoise"), systemImage: "flag.fill", fragment: "flag:6", role: .flag(6)),
            FilterNode(title: L10n.text("Purple"), systemImage: "flag.fill", fragment: "flag:7", role: .flag(7)),
        ]
    }

    static func decks(_ names: [String]) -> [FilterNode] {
        names.map { name in
            FilterNode(
                title: String(name.split(separator: "::").last ?? Substring(name)),
                systemImage: "books.vertical",
                fragment: "deck:\"\(name)\"",
                role: nil
            )
        }
    }

    static func notetypes(_ names: [String]) -> [FilterNode] {
        names.map { name in
            FilterNode(title: name, systemImage: "doc.text", fragment: "note:\"\(name)\"", role: nil)
        }
    }

    static func tags(_ tags: [String]) -> [FilterNode] {
        var nodes = [
            FilterNode(title: "Untagged", systemImage: "tag.slash", fragment: "tag:none", role: nil),
        ]
        nodes.append(contentsOf: tags.map { tag in
            FilterNode(title: tag, systemImage: "tag", fragment: "tag:\"\(tag)\"", role: nil)
        })
        return nodes
    }

    private static func makeNode(title: String, image: String, fragment: String) -> FilterNode {
        FilterNode(title: title, systemImage: image, fragment: fragment, role: nil)
    }
}

/// Anki's seven brand flag hues (same values as desktop / the sidebar).
enum BrowseFlagSwatch {
    static func color(for value: UInt32) -> Color? {
        switch value & 0b111 {
        case 1: Color(ankiFlagHex: 0xFF3B30)
        case 2: Color(ankiFlagHex: 0xFF9500)
        case 3: Color(ankiFlagHex: 0x34C759)
        case 4: Color(ankiFlagHex: 0x007AFF)
        case 5: Color(ankiFlagHex: 0xFF2D55)
        case 6: Color(ankiFlagHex: 0x32ADE6)
        case 7: Color(ankiFlagHex: 0xAF52DE)
        default: nil
        }
    }
}

private extension Color {
    init(ankiFlagHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Semantic note index (spec D4 / §4.6)

/// Per-device, OUT-OF-SYNC embedding corpus for semantic fallback search
/// and fuzzy near-duplicate detection. Never lives in col.conf (whole-blob
/// LWW would thrash); resides beside the profile's collection folder.
///
/// Duplicate comparison is scoped; full-library retrieval uses the shared
/// profile coordinator and its persisted passage index.
@MainActor
@Observable
package final class SemanticNoteIndex {
    package static let shared = SemanticNoteIndex()

    struct Entry: Codable, Sendable {
        /// FNV-1a of the source text — cheap staleness invalidation.
        var textHash: UInt64
        var vector: [Float]
    }

    private struct DiskShape: Codable {
        var version: Int
        var modelVersion: Int?
        var modelIdentity: String?
        var entries: [Int64: Entry]
    }

    static let version = 2
    /// Cosine threshold above which two texts are near-duplicates.
    static let nearDupeThreshold: Float = 0.95

    private(set) var entries: [Int64: Entry] = [:]
    private var fileURL: URL?
    private var loadAttempted = false
    private var isBuilding = false
    private var profileGeneration = 0
    private var activeModelVersion: Int?
    private var activeModelIdentity: String?

    var isReady: Bool { !entries.isEmpty }
    var progressDescription: String? { isBuilding ? "Building semantic index…" : nil }

    private init() {}

    private func resolveFileURL() -> URL {
        if let fileURL { return fileURL }
        let dir = AccountStore.profileDirectory(for: AccountStore.shared.current.id)
        let model = activeModelVersion.map(String.init) ?? "unavailable"
        let url = dir.appendingPathComponent("semantic-index-v\(Self.version)-m\(model).json")
        fileURL = url
        return url
    }

    private func synchronizeModelIdentity() {
        let current = NoteEmbedderBridge.installedModelVersion
        let identity = current == nil ? nil : TextEmbedder.modelIdentity
        guard current != activeModelVersion || identity != activeModelIdentity else { return }
        activeModelVersion = current
        activeModelIdentity = identity
        profileGeneration &+= 1
        entries.removeAll(keepingCapacity: false)
        fileURL = nil
        loadAttempted = false
        isBuilding = false
    }

    private func loadIfNeeded() {
        synchronizeModelIdentity()
        guard !loadAttempted else { return }
        loadAttempted = true
        let url = resolveFileURL()
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(DiskShape.self, from: data),
              shape.version == Self.version,
              shape.modelVersion == activeModelVersion,
              shape.modelIdentity == activeModelIdentity else { return }
        entries = shape.entries.filter { $0.value.vector.count == 768 && $0.value.vector.allSatisfy(\.isFinite) }
    }

    private func persist() {
        let shape = DiskShape(
            version: Self.version,
            modelVersion: activeModelVersion,
            modelIdentity: activeModelIdentity,
            entries: entries
        )
        if let data = try? JSONEncoder().encode(shape) {
            try? data.write(to: resolveFileURL(), options: .atomic)
        }
    }

    /// Invalidates every in-memory and on-disk path decision after a profile
    /// switch. In-flight embedding checks the generation again before it can
    /// publish IDs from the previous collection.
    package func resetForProfileSwitch() {
        profileGeneration &+= 1
        entries.removeAll(keepingCapacity: false)
        fileURL = nil
        loadAttempted = false
        isBuilding = false
    }

    /// Updates the loaded Browse window; the full coordinator owns retrieval.
    /// Failures degrade silently — semantic features simply stay sparse.
    func updateCorpus(with records: [NoteRecord]) async {
        guard !records.isEmpty, !isBuilding else { return }
        loadIfNeeded()
        isBuilding = true
        let generation = profileGeneration
        let modelVersion = activeModelVersion
        defer { if profileGeneration == generation { isBuilding = false } }

        var changed: [(Int64, String, UInt64, Int64)] = []
        for record in records {
            let text = Self.corpusText(of: record)
            let hash = BrowseFnv.fnv1a(text)
            if let existing = entries[record.id.rawValue], existing.textHash == hash { continue }
            guard !text.isEmpty else { continue }
            changed.append((record.id.rawValue, text, hash, record.mod))
        }

        for (id, text, hash, mod) in changed {
            guard !Task.isCancelled else { return }
            // The collection index already embedded this note at this mtime;
            // reuse its pooled vector instead of a second forward pass.
            var vector = await CollectionRetrievalCoordinator.shared.indexedNoteVector(id, mod: mod)
            if vector == nil { vector = await NoteEmbedderBridge.embedPassage(text) }
            guard let vector else { continue }
            guard profileGeneration == generation,
                  activeModelVersion == modelVersion else { return }
            entries[id] = Entry(textHash: hash, vector: vector)
        }
        // Browse supplies a partial window, so it cannot authoritatively prune
        // the collection. The full profile coordinator owns source deletion.
        if !changed.isEmpty { persist() }

    }

    /// All note fields and tags, with markup removed.
    nonisolated static func corpusText(of record: NoteRecord) -> String {
        let fields = record.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        let raw = fields.joined(separator: "\n") + "\nTags: " + record.tags
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

    }

    /// Top-k note ids close in meaning to `query`, strongest first. nil ⇒
    /// engine or index unusable right now.
    ///
    /// Two cuts, after DigUp (same EmbeddingGemma 2 model): a note must stand
    /// out from the collection by `gate` standard deviations for this query,
    /// and reach `ratio` of the strongest note's strength. Rank fusion alone
    /// always returns a "best" few even when nothing is close; the gate gives
    /// an honest "nothing", the ratio drops the long weak tail.
    func search(
        _ query: String,
        topK: Int = 50,
        gate: Float = 2.0,
        ratio: Float = 0.5
    ) async -> [Int64]? {
        do {
            // Meaning only: Browse's direct hits already cover exact words, so
            // the keyword pass would be duplicate work on every keystroke.
            let hits = try await CollectionRetrievalCoordinator.shared.search(
                query, limit: topK, filter: RetrievalFilter(sourcePrefixes: ["note:"]), lexical: false
            )
            let scored = hits.compactMap { hit -> (id: Int64, strength: Float)? in
                guard hit.segment.sourceID.hasPrefix("note:"),
                      let id = Int64(hit.segment.sourceID.dropFirst(5)),
                      let strength = hit.semanticStrength, strength >= gate else { return nil }
                return (id, strength)
            }
            guard let top = scored.map(\.strength).max() else { return [] }
            return scored
                .filter { $0.strength >= top * ratio }
                .sorted { $0.strength > $1.strength }
                .map(\.id)
        } catch { return nil }
    }

    /// Groups of near-duplicate texts (cosine ≥ threshold). Scope-limited:
    /// O(n²) over whatever ids arrive — callers pass the current window.
    func nearDuplicateGroups(scope ids: [Int64]) -> [[Int64]] {
        guard entries.count >= 2 else { return [] }
        let scoped = ids.filter { entries[$0] != nil }
        var assigned = Set<Int64>()
        var groups: [[Int64]] = []
        for i in scoped.indices {
            guard !assigned.contains(scoped[i]),
                  let vi = entries[scoped[i]]?.vector else { continue }
            var group = [scoped[i]]
            innerLoop: for j in (i + 1)..<scoped.count {
                guard !assigned.contains(scoped[j]),
                      let vj = entries[scoped[j]]?.vector else { continue }
                if NoteEmbedderBridge.cosine(vi, vj) >= Self.nearDupeThreshold {
                    group.append(scoped[j])
                    assigned.insert(scoped[j])
                    if group.count >= 12 { break innerLoop }
                }
            }
            if group.count >= 2 {
                group.forEach { assigned.insert($0) }
                groups.append(group)
            }
        }
        return groups
    }
}
