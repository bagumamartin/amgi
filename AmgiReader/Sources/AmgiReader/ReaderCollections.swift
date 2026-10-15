public import Foundation

/// Something that can sit in the library grid and be moved around in it: a
/// book or a collection.
public enum ReaderLibraryItemRef: Hashable, Sendable {
    case book(String)
    case collection(String)

    private static let bookPrefix = "amgi.library.book:"
    private static let collectionPrefix = "amgi.library.collection:"

    /// Drag payload. Plain text with a prefix nothing else produces, so a drop
    /// of arbitrary text from another app is rejected rather than misread as
    /// a book ID.
    public var dragString: String {
        switch self {
        case .book(let id): Self.bookPrefix + id
        case .collection(let id): Self.collectionPrefix + id
        }
    }

    public init?(dragString: String) {
        if dragString.hasPrefix(Self.bookPrefix) {
            let id = String(dragString.dropFirst(Self.bookPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .book(id)
        } else if dragString.hasPrefix(Self.collectionPrefix) {
            let id = String(dragString.dropFirst(Self.collectionPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .collection(id)
        } else {
            return nil
        }
    }
}

/// A user-made group of books (and of other collections).
public struct ReaderCollection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    /// The collection this one sits in; nil at the library's top level.
    public var parentID: String?
    public var createdAt: Date
    /// Bumped by every rename, move and delete. Merges between devices keep
    /// the newer copy of each collection.
    public var updatedAt: Date
    /// Set instead of removing the collection, so a merge with a device that
    /// still has it cannot bring it back.
    public var deletedAt: Date?

    public init(
        id: String,
        name: String,
        parentID: String?,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

/// Where one book is filed, and when it was put there.
public struct ReaderBookPlacement: Codable, Equatable, Sendable {
    /// nil: the top level.
    public var collectionID: String?
    public var updatedAt: Date

    public init(collectionID: String?, updatedAt: Date) {
        self.collectionID = collectionID
        self.updatedAt = updatedAt
    }
}

/// The library's folder structure.
///
/// Folder semantics, like the Home Screen: every book and every collection
/// sits in exactly one place — the top level or one collection — so moving
/// something takes it out of wherever it was. A book with no placement is at
/// the top level, which is also where every newly imported book lands.
///
/// Built to merge across devices: every collection and every placement
/// carries its own timestamp and the newer one wins, deletes leave a
/// tombstone, and anything filed in a deleted collection reads as being in
/// that collection's parent. Placements are never pruned against the live
/// book list, so a book whose iCloud copy is still downloading keeps its
/// place.
public struct ReaderCollectionTree: Codable, Equatable, Sendable {
    /// Every collection ever made here or merged in, tombstones included.
    /// Read through the query methods, which skip the tombstones.
    public private(set) var collections: [String: ReaderCollection]
    public private(set) var bookPlacements: [String: ReaderBookPlacement]

    public init(
        collections: [String: ReaderCollection] = [:],
        bookPlacements: [String: ReaderBookPlacement] = [:]
    ) {
        self.collections = collections
        self.bookPlacements = bookPlacements
    }

    private enum CodingKeys: String, CodingKey {
        case collections, bookPlacements
        /// The first, unsynced format: book ID → collection ID.
        case bookParents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collections = try container.decodeIfPresent([String: ReaderCollection].self, forKey: .collections) ?? [:]
        if let placements = try container.decodeIfPresent(
            [String: ReaderBookPlacement].self,
            forKey: .bookPlacements
        ) {
            bookPlacements = placements
        } else {
            let legacy = try container.decodeIfPresent([String: String].self, forKey: .bookParents) ?? [:]
            bookPlacements = legacy.mapValues {
                ReaderBookPlacement(collectionID: $0, updatedAt: .distantPast)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(collections, forKey: .collections)
        try container.encode(bookPlacements, forKey: .bookPlacements)
    }

    // MARK: Queries

    /// A collection that exists and is not deleted.
    public func collection(_ id: String) -> ReaderCollection? {
        collections[id].flatMap { $0.isDeleted ? nil : $0 }
    }

    /// Every live collection.
    public var liveCollections: [ReaderCollection] {
        collections.values.filter { !$0.isDeleted }
    }

    /// Where an item sits: a live collection ID, or nil for the top level.
    public func parent(of item: ReaderLibraryItemRef) -> String? {
        switch item {
        case .book(let id): resolve(bookPlacements[id]?.collectionID)
        case .collection(let id): resolve(collections[id]?.parentID)
        }
    }

    /// Collections directly inside `parentID` (nil: the top level).
    public func childCollections(of parentID: String?) -> [ReaderCollection] {
        liveCollections.filter { resolve($0.parentID) == parentID }
    }

    /// Whether `bookID` sits directly inside `parentID` (nil: the top level).
    public func contains(bookID: String, directlyIn parentID: String?) -> Bool {
        parent(of: .book(bookID)) == parentID
    }

    /// Every book anywhere under `collectionID`, nearest first: its own books
    /// in `order`, then each sub-collection's in turn. What a collection's
    /// cover collage and count are drawn from.
    public func booksUnder(_ collectionID: String, ordering order: [String]) -> [String] {
        var visited: Set<String> = []
        return booksUnder(collectionID, ordering: order, visited: &visited)
    }

    private func booksUnder(_ collectionID: String, ordering order: [String], visited: inout Set<String>) -> [String] {
        guard visited.insert(collectionID).inserted else { return [] }
        var result = order.filter { parent(of: .book($0)) == collectionID }
        let children = childCollections(of: collectionID)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for child in children {
            result += booksUnder(child.id, ordering: order, visited: &visited)
        }
        return result
    }

    /// `ancestor` itself or any collection above `collectionID`.
    public func isWithin(_ collectionID: String, ancestor: String) -> Bool {
        var current: String? = collectionID
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = parent(of: .collection(id))
        }
        return false
    }

    /// Top level first, ending at `collectionID`.
    public func path(to collectionID: String) -> [ReaderCollection] {
        var result: [ReaderCollection] = []
        var current = collection(collectionID)
        var seen: Set<String> = []
        while let collection = current, seen.insert(collection.id).inserted {
            result.insert(collection, at: 0)
            current = parent(of: .collection(collection.id)).flatMap { self.collection($0) }
        }
        return result
    }

    /// Whether `item` may be moved into `destination` (nil: the top level).
    /// A collection can't go inside itself or anything under it.
    public func canMove(_ item: ReaderLibraryItemRef, to destination: String?) -> Bool {
        if let destination, collection(destination) == nil { return false }
        switch item {
        case .book:
            return true
        case .collection(let id):
            guard collection(id) != nil else { return false }
            guard let destination else { return true }
            return !isWithin(destination, ancestor: id)
        }
    }

    /// Follows a stored parent ID up past deleted (or unknown) collections to
    /// the nearest live one.
    private func resolve(_ parentID: String?) -> String? {
        var current = parentID
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            guard let collection = collections[id] else { return nil }
            if !collection.isDeleted { return id }
            current = collection.parentID
        }
        return nil
    }

    // MARK: Mutations

    /// Creates an empty collection and returns its ID.
    @discardableResult
    public mutating func createCollection(
        named name: String,
        in parentID: String?,
        now: Date = .now
    ) -> String {
        let id = "collection-" + UUID().uuidString.lowercased()
        collections[id] = ReaderCollection(
            id: id,
            name: Self.cleanName(name),
            parentID: parentID.flatMap { collection($0)?.id },
            createdAt: now,
            updatedAt: now
        )
        return id
    }

    public mutating func rename(_ collectionID: String, to name: String, now: Date = .now) {
        guard collection(collectionID) != nil else { return }
        collections[collectionID]?.name = Self.cleanName(name)
        collections[collectionID]?.updatedAt = now
    }

    /// Deletes a collection. Its books and sub-collections move up into its
    /// parent: deleting a collection never deletes what was in it.
    public mutating func delete(_ collectionID: String, now: Date = .now) {
        guard collection(collectionID) != nil else { return }
        let parent = parent(of: .collection(collectionID))
        for (bookID, placement) in bookPlacements where resolve(placement.collectionID) == collectionID {
            bookPlacements[bookID] = ReaderBookPlacement(collectionID: parent, updatedAt: now)
        }
        for child in childCollections(of: collectionID) {
            collections[child.id]?.parentID = parent
            collections[child.id]?.updatedAt = now
        }
        collections[collectionID]?.deletedAt = now
        collections[collectionID]?.updatedAt = now
    }

    /// Moves `item` into `destination` (nil: the top level). Returns false —
    /// and changes nothing — for a move `canMove` rejects.
    @discardableResult
    public mutating func move(
        _ item: ReaderLibraryItemRef,
        to destination: String?,
        now: Date = .now
    ) -> Bool {
        guard canMove(item, to: destination) else { return false }
        switch item {
        case .book(let id):
            bookPlacements[id] = ReaderBookPlacement(collectionID: destination, updatedAt: now)
        case .collection(let id):
            collections[id]?.parentID = destination
            collections[id]?.updatedAt = now
        }
        return true
    }

    /// A name for a new collection that no sibling already uses:
    /// "New Collection", then "New Collection 2", …
    public func unusedName(_ base: String, in parentID: String?) -> String {
        let taken = Set(childCollections(of: parentID).map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

    private static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Collection" : trimmed
    }

    // MARK: Merging

    /// Combines two devices' trees: per collection and per book, the newer
    /// entry wins (a tombstone wins a tie, so a delete is never undone by an
    /// equal-aged copy). Deterministic and order-independent, so every device
    /// converges on the same tree whichever merged first.
    public static func merged(_ lhs: ReaderCollectionTree, _ rhs: ReaderCollectionTree) -> ReaderCollectionTree {
        var collections = lhs.collections
        for (id, theirs) in rhs.collections {
            guard let ours = collections[id] else {
                collections[id] = theirs
                continue
            }
            if newer(theirs, than: ours) { collections[id] = theirs }
        }
        var placements = lhs.bookPlacements
        for (id, theirs) in rhs.bookPlacements {
            guard let ours = placements[id] else {
                placements[id] = theirs
                continue
            }
            if theirs.updatedAt > ours.updatedAt
                || (theirs.updatedAt == ours.updatedAt
                    && (theirs.collectionID ?? "") > (ours.collectionID ?? "")) {
                placements[id] = theirs
            }
        }
        var tree = ReaderCollectionTree(collections: collections, bookPlacements: placements)
        tree.breakCycles()
        return tree
    }

    private static func newer(_ a: ReaderCollection, than b: ReaderCollection) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.isDeleted != b.isDeleted { return a.isDeleted }
        return (a.parentID ?? "", a.name) > (b.parentID ?? "", b.name)
    }

    /// Two devices can each move one collection into the other between
    /// syncs, and the merge then holds a loop that hangs off nothing. Each
    /// loop is cut at its most recently moved member, which goes to the top
    /// level — the same choice on every device, since it depends only on the
    /// merged data.
    private mutating func breakCycles() {
        for start in liveCollections.map(\.id).sorted() {
            var chain: [String] = []
            var current: String? = start
            while let id = current {
                if let loopStart = chain.firstIndex(of: id) {
                    let loop = chain[loopStart...]
                    let cut = loop.max { lhs, rhs in
                        let l = collections[lhs]!, r = collections[rhs]!
                        return (l.updatedAt, l.id) < (r.updatedAt, r.id)
                    }!
                    collections[cut]?.parentID = nil
                    break
                }
                chain.append(id)
                current = resolve(collections[id]?.parentID)
            }
        }
    }
}

/// Per-profile persistence for the collection tree, beside reading progress
/// and under the same profile scoping. Local to this device.
// `UserDefaults` is thread-safe but not formally `Sendable`.
public struct ReaderCollectionStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String

    public init(profileID: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let sanitized = profileID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
        self.key = "amgi.reader.collections__\(sanitized.isEmpty ? "default" : sanitized)"
    }

    /// Scoped to the profile selected in `UserDefaults.standard`. Reads the
    /// `amgi.selectedUser` anchor directly for the reason
    /// `ReaderProgressStore.forCurrentProfile` does.
    public static func forCurrentProfile(userDefaults: UserDefaults = .standard) -> ReaderCollectionStore {
        ReaderCollectionStore(
            profileID: userDefaults.string(forKey: "amgi.selectedUser") ?? "default",
            userDefaults: userDefaults
        )
    }

    public func load() -> ReaderCollectionTree {
        guard let data = userDefaults.data(forKey: key),
              let tree = try? JSONDecoder().decode(ReaderCollectionTree.self, from: data) else {
            return ReaderCollectionTree()
        }
        return tree
    }

    public func save(_ tree: ReaderCollectionTree) {
        guard let data = try? JSONEncoder().encode(tree) else { return }
        userDefaults.set(data, forKey: key)
    }
}
