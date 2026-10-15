import Foundation
import Testing
@testable import AmgiReader

/// Library collections are folders: one place per item, nesting allowed,
/// no cycles, and deleting a collection never loses what was in it.
@Suite("Reader collection tree")
struct ReaderCollectionTreeTests {
    @Test("a moved book leaves the top level and lands in one collection")
    func moveBook() {
        var tree = ReaderCollectionTree()
        let a = tree.createCollection(named: "A", in: nil)
        let b = tree.createCollection(named: "B", in: nil)

        #expect(tree.contains(bookID: "book1", directlyIn: nil))
        let moved1 = tree.move(.book("book1"), to: a)
        #expect(moved1)
        #expect(tree.parent(of: .book("book1")) == a)
        #expect(!tree.contains(bookID: "book1", directlyIn: nil))

        let moved2 = tree.move(.book("book1"), to: b)
        #expect(moved2)
        #expect(tree.parent(of: .book("book1")) == b)
        let moved3 = tree.move(.book("book1"), to: nil)
        #expect(moved3)
        #expect(tree.parent(of: .book("book1")) == nil)
    }

    @Test("collections nest, but never into themselves or their descendants")
    func noCycles() {
        var tree = ReaderCollectionTree()
        let outer = tree.createCollection(named: "Outer", in: nil)
        let inner = tree.createCollection(named: "Inner", in: outer)
        let leaf = tree.createCollection(named: "Leaf", in: inner)

        let moved4 = tree.move(.collection(outer), to: outer)
        #expect(!moved4)
        let moved5 = tree.move(.collection(outer), to: leaf)
        #expect(!moved5)
        #expect(tree.parent(of: .collection(outer)) == nil)
        #expect(tree.path(to: leaf).map(\.name) == ["Outer", "Inner", "Leaf"])

        let moved6 = tree.move(.collection(leaf), to: nil)
        #expect(moved6)
        #expect(tree.parent(of: .collection(leaf)) == nil)
        let moved7 = tree.move(.collection(outer), to: leaf)
        #expect(moved7)
        #expect(tree.path(to: inner).map(\.name) == ["Leaf", "Outer", "Inner"])
    }

    @Test("deleting a collection moves its contents up a level")
    func deleteKeepsContents() {
        var tree = ReaderCollectionTree()
        let outer = tree.createCollection(named: "Outer", in: nil)
        let middle = tree.createCollection(named: "Middle", in: outer)
        let inner = tree.createCollection(named: "Inner", in: middle)
        tree.move(.book("b1"), to: middle)

        tree.delete(middle)

        #expect(tree.collection(middle) == nil)
        #expect(tree.parent(of: .book("b1")) == outer)
        #expect(tree.parent(of: .collection(inner)) == outer)
    }

    @Test("books under a collection include nested ones, nearest first")
    func booksUnder() {
        var tree = ReaderCollectionTree()
        let outer = tree.createCollection(named: "Outer", in: nil)
        let inner = tree.createCollection(named: "Inner", in: outer)
        tree.move(.book("deep"), to: inner)
        tree.move(.book("near"), to: outer)

        #expect(tree.booksUnder(outer, ordering: ["deep", "near", "loose"]) == ["near", "deep"])
    }

    @Test("moves into a missing collection are refused")
    func missingDestination() {
        var tree = ReaderCollectionTree()
        let moved8 = tree.move(.book("b1"), to: "collection-gone")
        #expect(!moved8)
        #expect(tree.parent(of: .book("b1")) == nil)
    }

    @Test("new names avoid siblings, and blank names get a fallback")
    func naming() {
        var tree = ReaderCollectionTree()
        let first = tree.createCollection(named: tree.unusedName("New Collection", in: nil), in: nil)
        let second = tree.createCollection(named: tree.unusedName("New Collection", in: nil), in: nil)
        #expect(tree.collection(first)?.name == "New Collection")
        #expect(tree.collection(second)?.name == "New Collection 2")

        tree.rename(first, to: "   ")
        #expect(tree.collection(first)?.name == "Untitled Collection")
    }

    @Test("drag payloads round-trip and reject foreign text")
    func dragPayload() {
        for ref in [ReaderLibraryItemRef.book("epub-1"), .collection("collection-x")] {
            #expect(ReaderLibraryItemRef(dragString: ref.dragString) == ref)
        }
        #expect(ReaderLibraryItemRef(dragString: "hello") == nil)
        #expect(ReaderLibraryItemRef(dragString: "amgi.library.book:") == nil)
    }

    @Test("the store round-trips per profile")
    func storeScoping() {
        let defaults = UserDefaults(suiteName: "amgi.tests.collections.\(UUID().uuidString)") ?? .standard
        var tree = ReaderCollectionTree()
        tree.createCollection(named: "Mine", in: nil)
        ReaderCollectionStore(profileID: "alice", userDefaults: defaults).save(tree)

        #expect(ReaderCollectionStore(profileID: "alice", userDefaults: defaults).load() == tree)
        #expect(ReaderCollectionStore(profileID: "bob", userDefaults: defaults).load().collections.isEmpty)
    }

    // MARK: Merging across devices

    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    @Test("the newer placement of a book wins, whichever side it is on")
    func placementLastWriterWins() {
        var base = ReaderCollectionTree()
        let a = base.createCollection(named: "A", in: nil, now: early)
        let b = base.createCollection(named: "B", in: nil, now: early)
        var phone = base, pad = base
        phone.move(.book("b1"), to: a, now: early)
        pad.move(.book("b1"), to: b, now: late)

        #expect(ReaderCollectionTree.merged(phone, pad).parent(of: .book("b1")) == b)
        #expect(ReaderCollectionTree.merged(pad, phone).parent(of: .book("b1")) == b)
    }

    @Test("a delete survives a merge with a device that still has the collection")
    func tombstoneWins() {
        var base = ReaderCollectionTree()
        let shelf = base.createCollection(named: "Shelf", in: nil, now: early)
        base.move(.book("b1"), to: shelf, now: early)
        var phone = base
        phone.delete(shelf, now: late)

        let merged = ReaderCollectionTree.merged(base, phone)
        #expect(merged.collection(shelf) == nil)
        #expect(merged.parent(of: .book("b1")) == nil)
    }

    @Test("a book filed in a collection deleted elsewhere reads as its parent's")
    func orphanedPlacementFallsUp() {
        var base = ReaderCollectionTree()
        let outer = base.createCollection(named: "Outer", in: nil, now: early)
        let inner = base.createCollection(named: "Inner", in: outer, now: early)
        var phone = base, pad = base
        pad.move(.book("new"), to: inner, now: late)
        phone.delete(inner, now: late)

        #expect(ReaderCollectionTree.merged(phone, pad).parent(of: .book("new")) == outer)
    }

    @Test("crossed moves on two devices are cut into a tree, the same way on both")
    func crossedMovesBreakTheLoop() {
        var base = ReaderCollectionTree()
        let x = base.createCollection(named: "X", in: nil, now: early)
        let y = base.createCollection(named: "Y", in: nil, now: early)
        var phone = base, pad = base
        phone.move(.collection(x), to: y, now: early.addingTimeInterval(1))
        pad.move(.collection(y), to: x, now: late)

        let one = ReaderCollectionTree.merged(phone, pad)
        let other = ReaderCollectionTree.merged(pad, phone)
        #expect(one == other)
        #expect(one.parent(of: .collection(y)) == nil)
        #expect(one.parent(of: .collection(x)) == y)
    }

    @Test("the first, timestamp-free format still loads")
    func legacyFormatDecodes() throws {
        let json = #"{"collections":{},"bookParents":{"b1":"c1"}}"#
        let tree = try JSONDecoder().decode(ReaderCollectionTree.self, from: Data(json.utf8))
        #expect(tree.bookPlacements["b1"]?.collectionID == "c1")
    }
}

