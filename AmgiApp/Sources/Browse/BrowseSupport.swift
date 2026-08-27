// AmgiApp/Sources/Browse/BrowseSupport.swift
import AnkiBackend
import AnkiClients
import AnkiIcons
import Dependencies
import Foundation

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
        try? backend.setConfigJSONValue(stored, for: Self.configKey)
        refresh()
    }

    func delete(name: String) {
        var stored: [String: String] =
            (try? backend.getConfigJSONValue(for: Self.configKey)) ?? [:]
        stored.removeValue(forKey: name)
        try? backend.setConfigJSONValue(stored, for: Self.configKey)
        refresh()
    }

    func rename(from oldName: String, to newName: String) {
        guard let existing = searches.first(where: { $0.name == oldName }) else { return }
        delete(name: oldName)
        save(name: newName, query: existing.query)
    }
}

// MARK: - Filter rail sections (spec §5.5)

/// One tappable sidebar/filter entry.
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

    enum Role { case state(BrowseModelStateColor), flag(UInt32) }

    var id: String { title + "#" + fragment }

    init(title: String, systemImage: String, fragment: String, role: Role?) {
        self.title = title
        self.systemImage = systemImage
        self.fragment = fragment
        self.role = role
    }
}

enum BrowseModelStateColor {
    case newState, learning, review, suspended, buried
}

/// Static sections of the filter rail mirroring desktop stages.
enum BrowseFilterSections {
    static func today() -> [FilterNode] {
        [
            ("Due today", "clock.badge.checkmark", "due:today"),
            ("Added today", "plus.circle", "added:1"),
            ("Edited today", "pencil", "edited:1"),
            ("Studied today", "checkmark.seal", "rated:1"),
            ("First review", "flag.checkered", "introduced:1"),
            ("Again today", "arrow.uturn.backward", "rated:1:1"),
            ("Overdue", "exclamationmark.triangle", "is:due -due:today"),
        ]
        .map { FilterNode(title: $0.0, systemImage: $0.1, fragment: $0.2, role: nil) }
    }

    static func cardStates() -> [FilterNode] {
        [
            FilterNode(title: "New", systemImage: "circle", fragment: "is:new",
                       tintedRole: .state(.newState)),
            FilterNode(title: "Learning", systemImage: "circle.fill", fragment: "is:learn",
                       tintedRole: .state(.learning)),
            FilterNode(title: "Review", systemImage: "circle.circle", fragment: "is:review",
                       tintedRole: .state(.review)),
            FilterNode(title: "Suspended", systemImage: "pause.circle", fragment: "is:suspended",
                       tintedRole: .state(.suspended)),
            FilterNode(title: "Buried", systemImage: "archivebox", fragment: "is:buried",
                       tintedRole: .state(.buried)),
        ]
    }

    static func flags() -> [FilterNode] {
        [
            FilterNode(title: "No flag", systemImage: "flag.slash", fragment: "-flag:any", role: nil),
            FilterNode(title: "Red", systemImage: "flag.fill", fragment: "flag:red", role: .flag(1)),
            FilterNode(title: "Orange", systemImage: "flag.fill", fragment: "flag:orange", role: .flag(2)),
            FilterNode(title: "Green", systemImage: "flag.fill", fragment: "flag:green", role: .flag(3)),
            FilterNode(title: "Blue", systemImage: "flag.fill", fragment: "flag:blue", role: .flag(4)),
            FilterNode(title: "Pink", systemImage: "flag.fill", fragment: "flag:pink", role: .flag(5)),
            FilterNode(title: "Turquoise", systemImage: "flag.fill", fragment: "flag:turquoise", role: .flag(6)),
            FilterNode(title: "Purple", systemImage: "flag.fill", fragment: "flag:purple", role: .flag(7)),
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
            FilterNode(title: "Untagged", systemImage: "tag.slash", fragment: "-tag:*", role: nil),
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

private extension Array where Element == (String, String, String) {
    func map(_ transform: (String, String, String) -> FilterNode) -> [FilterNode] {
        self.map(transform)
    }
}

// MARK: - Semantic note index (spec D4 / §4.6)

/// Per-device, OUT-OF-SYNC embedding corpus for semantic fallback search
/// and fuzzy near-duplicate detection. Never lives in col.conf (whole-blob
/// LWW would thrash); resides beside the profile's collection folder.
///
/// MVP sizing honesty: brute-force cosine over ≤~2000 indexed notes costs
/// single-digit milliseconds via plain dot products — no ANN needed until
/// measured evidence says otherwise.
@MainActor
final class SemanticNoteIndex {
    static let shared = SemanticNoteIndex()

    struct Entry: Codable, Sendable {
        /// FNV-1a of the source text — cheap staleness invalidation.
        var textHash: UInt64
        var vector: [Float]
    }

    private struct DiskShape: Codable {
        var version: Int
        var entries: [Int64: Entry]
    }

    static let version = 1
    /// Corpus cap keeps the initial build bounded (~2000 × ~1 KB fp16-less
    /// JSON ≈ few MB). Scan cost stays trivially fast at this size.
    static let corpusCap = 2000
    /// Cosine threshold above which two texts are near-duplicates.
    static let nearDupeThreshold: Float = 0.95

    private(set) var entries: [Int64: Entry] = [:]
    private var fileURL: URL?
    private var loadAttempted = false
    private var isBuilding = false

    var isReady: Bool { !entries.isEmpty }
    var progressDescription: String? { isBuilding ? "Building semantic index…" : nil }

    private init() {}

    private func resolveFileURL() -> URL {
        if let fileURL { return fileURL }
        let dir = AccountStore.profileDirectory(for: AccountStore.shared.current.id)
        let url = dir.appendingPathComponent("semantic-index.json")
        fileURL = url
        return url
    }

    private func loadIfNeeded() {
        guard !loadAttempted else { return }
        loadAttempted = true
        let url = resolveFileURL()
        guard let data = try? Data(contentsOf: url),
              let shape = try? JSONDecoder().decode(DiskShape.self, from: data),
              shape.version == Self.version else { return }
        entries = shape.entries.filter { $0.value.vector.count == TextEmbedder.dimensionValue }
    }

    private func persist() {
        let shape = DiskShape(version: Self.version, entries: entries)
        if let data = try? JSONEncoder().encode(shape) {
            try? data.write(to: resolveFileURL(), options: .atomic)
        }
    }

    /// Embeds any changed/new notes (bounded corpus), evicting stale ones.
    /// Failures degrade silently — semantic features simply stay sparse.
    func updateCorpus(with records: [NoteRecord]) async {
        guard !records.isEmpty, !isBuilding else { return }
        loadIfNeeded()
        isBuilding = true
        defer { isBuilding = false }

        // Recent-first keeps the most useful slice under the cap.
        var changed: [(Int64, String, UInt64)] = []
        let liveIDs = Set(records.prefix(Self.corpusCap).map(\.id.rawValue))
        for record in records.prefix(Self.corpusCap) {
            let text = Self.corpusText(of: record)
            let hash = BrowseFnv.fnv1a(text)
            if let existing = entries[record.id.rawValue], existing.textHash == hash { continue }
            guard !text.isEmpty else { continue }
            changed.append((record.id.rawValue, text, hash))
        }

        for (id, text, hash) in changed.prefix(Self.corpusCap) {
            guard let vector = try? await TextEmbedder.shared.embed(text, prefix: .passage) else { break }
            entries[id] = Entry(textHash: hash, vector: vector)
        }
        // Drop ids that vanished from the corpus.
        let removed = entries.keys.filter { !liveIDs.contains($0) }
        for key in removed { entries.removeValue(forKey: key) }

        if !changed.isEmpty { persist() }
    }

    /// First non-empty trimmed field, HTML-stripped (fields split on \u{1f}).
    static func corpusText(of record: NoteRecord) -> String {
        let fields = record.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        let raw = fields.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? record.sfld
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Top-k note ids semantically similar to `query`. nil ⇒ engine or
    /// index unusable right now (UI hides the affordance).
    func search(_ query: String, topK: Int = 50) async -> [Int64]? {
        guard isReady, !query.isEmpty else { return nil }
        loadIfNeeded()
        guard let queryVector = try? await TextEmbedder.shared.embed(query, prefix: .query) else {
            return nil
        }
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(entries.count)
        for (id, entry) in entries {
            scored.append((id, TextEmbedder.cosine(queryVector, entry.vector)))
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(topK).map(\.0))
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
                if TextEmbedder.cosine(vi, vj) >= Self.nearDupeThreshold {
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
