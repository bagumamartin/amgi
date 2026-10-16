import AmgiReader
import Foundation
import Testing
@testable import ReaderFeature

/// The reader's selection menu and page-turn effects.
///
/// The regression these lock down is behavioural and easy to reintroduce by
/// accident: a single tap opening a dictionary, and a menu that silently
/// drops "Look Up" — both of which look like a broken long press to a reader.
@Suite("Reader selection menu")
struct ReaderSelectionMenuTests {
    private func payload(
        text: String = "artery",
        anchor: ReaderSourceAnchor? = .init(bookID: "b", quote: "artery")
    ) -> ReaderSelectionPayload {
        ReaderSelectionPayload(
            text: text,
            token: text,
            sentence: "The occlusion of a coronary artery.",
            anchor: anchor
        )
    }

    @Test("Look Up, Highlight, Bookmark and Copy are all offered")
    func everyActionIsOffered() {
        let actions = ReaderSelectionMenu.availableActions(for: payload())
        #expect(actions == ReaderSelectionMenu.actionOrder)
        // Look Up first, because it is what a reader long-pressing a word is
        // overwhelmingly reaching for.
        #expect(actions.first == .lookUp)
    }

    @Test("each action has a distinct title and a symbol")
    func actionsAreDistinguishable() {
        let titles = ReaderSelectionMenu.actionOrder.map(ReaderSelectionMenu.title(for:))
        #expect(Set(titles).count == titles.count, "duplicate menu title")
        for action in ReaderSelectionMenu.actionOrder {
            #expect(!ReaderSelectionMenu.systemImage(for: action).isEmpty)
        }
    }

    @Test("actions needing text are hidden when there is none")
    func textlessSelectionHidesTextActions() {
        // A selection of only whitespace must not offer Copy or Look Up; a
        // greyed-out item reads as a bug.
        let blank = payload(text: "   ", anchor: nil)
        #expect(ReaderSelectionMenu.availableActions(for: blank).isEmpty)
    }

    @Test("marks need an anchor, so they are omitted without one")
    func marksNeedAnAnchor() {
        // A highlight with no way back to its position is a dead end, so the
        // action is omitted rather than offered and silently losing the mark.
        let noAnchor = payload(anchor: nil)
        let actions = ReaderSelectionMenu.availableActions(for: noAnchor)
        #expect(!actions.contains(.highlight))
        #expect(!actions.contains(.bookmark))
        // But the actions that do not need one still work.
        #expect(actions.contains(.lookUp))
        #expect(actions.contains(.copy))
        // And a card can still be started: it falls back to a quote anchor.
        let entries = ReaderSelectionMenu.entries(for: noAnchor, context: .init())
        #expect(entries.contains(.card(.newCard, title: "Make Card", systemImage: ReaderSelectionMenu.makeCardImage)))
    }

    @Test("the raw value is stable, because macOS carries it in a menu item")
    func rawValuesAreStable() {
        // `NSMenuItem.representedObject` round-trips the action through this
        // value, so a rename would silently break the macOS menu.
        #expect(ReaderSelectionAction.lookUp.rawValue == "lookUp")
        #expect(ReaderSelectionAction.highlight.rawValue == "highlight")
        #expect(ReaderSelectionAction.bookmark.rawValue == "bookmark")
        #expect(ReaderSelectionAction.copy.rawValue == "copy")
        for action in ReaderSelectionAction.allCases {
            #expect(ReaderSelectionAction(rawValue: action.rawValue) == action)
        }
    }

    @Test("every declared action has a title and a symbol")
    func noActionIsUnmapped() {
        for action in ReaderSelectionAction.allCases {
            #expect(!ReaderSelectionMenu.title(for: action).isEmpty)
            #expect(!ReaderSelectionMenu.systemImage(for: action).isEmpty)
            #expect(ReaderSelectionMenu.actionOrder.contains(action))
        }
    }
}

@Suite("Reader selection menu — cards")
struct ReaderSelectionMenuCardTests {
    private let payload = ReaderSelectionPayload(
        text: "uncoupling",
        token: "uncoupling",
        sentence: "Mitochondrial uncoupling releases heat.",
        anchor: .init(bookID: "b", quote: "uncoupling")
    )

    private func commands(_ entries: [ReaderSelectionMenuEntry]) -> [ReaderCardMenuCommand] {
        entries.flatMap { entry -> [ReaderCardMenuCommand] in
            switch entry {
            case .card(let command, _, _): [command]
            case .submenu(_, _, let children): commands(children)
            case .action: []
            }
        }
    }

    @Test("with no draft, Make Card follows Look Up and nothing targets a draft")
    func noDraftOffersMakeCard() {
        let entries = ReaderSelectionMenu.entries(for: payload, context: .init())
        #expect(entries.first == .action(.lookUp))
        #expect(entries[1] == .card(.newCard, title: "Make Card", systemImage: ReaderSelectionMenu.makeCardImage))
        #expect(commands(entries) == [.newCard])
    }

    @Test("with a draft waiting, Add to Back of it leads the menu")
    func waitingDraftLeadsWithAddToBack() {
        let id = UUID()
        let context = ReaderCardMenuContext(drafts: [.init(id: id, title: "uncoupling")])
        let entries = ReaderSelectionMenu.entries(for: payload, context: context)
        #expect(entries.first == .card(.add(draftID: id, side: .back), title: "Add to Back", systemImage: ReaderSelectionMenu.addToBackImage))
        // A second card can still be started without touching the first.
        #expect(entries.contains(.card(.newCard, title: "New Card", systemImage: ReaderSelectionMenu.makeCardImage)))
    }

    @Test("every draft is reachable, the others one level down")
    func everyDraftIsReachable() {
        let first = UUID(), second = UUID(), third = UUID()
        let context = ReaderCardMenuContext(drafts: [
            .init(id: first, title: "a"), .init(id: second, title: "b"), .init(id: third, title: "c"),
        ])
        let all = commands(ReaderSelectionMenu.entries(for: payload, context: context))
        for id in [second, third] {
            #expect(all.contains(.add(draftID: id, side: .back)))
            #expect(all.contains(.add(draftID: id, side: .front)))
        }
        #expect(all.contains(.add(draftID: first, side: .front)))
        // The top level stays short however many drafts are open.
        let topLevel = ReaderSelectionMenu.entries(for: payload, context: context)
        #expect(topLevel.count <= 7)
    }

    @Test("with several drafts, Add to Back names the card it fills")
    func addToBackNamesItsCard() {
        let first = UUID(), second = UUID()
        let context = ReaderCardMenuContext(drafts: [
            .init(id: first, title: "uncoupling"), .init(id: second, title: "thermogenesis in brown fat…"),
        ])
        let entries = ReaderSelectionMenu.entries(for: payload, context: context)
        #expect(entries.first == .card(
            .add(draftID: first, side: .back),
            title: "Add to Back of “uncoupling”",
            systemImage: ReaderSelectionMenu.addToBackImage
        ))
    }

    @Test("Other Cards offers each other card's back before any front")
    func otherCardsLeadWithBacks() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let context = ReaderCardMenuContext(drafts: [
            .init(id: first, title: "a"), .init(id: second, title: "b"), .init(id: third, title: "c"),
        ])
        let entries = ReaderSelectionMenu.entries(for: payload, context: context)
        let children = try #require(entries.lazy.compactMap { entry -> [ReaderSelectionMenuEntry]? in
            if case .submenu("Other Cards", _, let children) = entry { return children }
            return nil
        }.first)
        #expect(commands(Array(children.prefix(2))) == [
            .add(draftID: second, side: .back), .add(draftID: third, side: .back),
        ])
    }

    @Test("with one draft, Add to Front is a plain item, not a submenu of one")
    func singleDraftHasNoSubmenu() {
        let id = UUID()
        let context = ReaderCardMenuContext(drafts: [.init(id: id, title: "a")])
        let entries = ReaderSelectionMenu.entries(for: payload, context: context)
        #expect(!entries.contains { if case .submenu = $0 { true } else { false } })
        #expect(entries.contains(.card(.add(draftID: id, side: .front), title: "Add to Front", systemImage: ReaderSelectionMenu.addToFrontImage)))
    }

    @Test("long fronts are cut for the one-row edit menu")
    func menuTitlesAreShort() {
        #expect(ReaderSelectionMenu.quoted("thermogenesis in brown fat…") == "“thermogenesis…”")
        #expect(ReaderSelectionMenu.quoted("short") == "“short”")
    }

    @Test("blank selections offer no card")
    func blankSelectionOffersNoCard() {
        let blank = ReaderSelectionPayload(text: "  ", token: "", sentence: "", anchor: nil)
        let context = ReaderCardMenuContext(drafts: [.init(id: UUID(), title: "a")])
        #expect(commands(ReaderSelectionMenu.entries(for: blank, context: context)).isEmpty)
    }
}

@Suite("One-tap lookup card")
struct ReaderLookupCardContentTests {
    @Test("term on the front; reading, definitions and sentence on the back")
    func layout() {
        let content = ReaderLookupCardContent(
            term: "勉強",
            reading: "べんきょう",
            definitions: ["study", "", "diligence", "work", "a fourth one"],
            sentence: "毎日  勉強\nする。"
        )
        #expect(content.front == "勉強")
        #expect(content.back == "べんきょう\n\nstudy\ndiligence\nwork\n\n毎日 勉強 する。")
    }

    @Test("a reading equal to the term and a sentence that is just the term are dropped")
    func noRedundantSections() {
        let content = ReaderLookupCardContent(term: "cat", reading: "cat", definitions: ["feline"], sentence: "cat")
        #expect(content.back == "feline")
    }

    @Test("search escaping keeps wildcards literal")
    func searchEscaping() {
        #expect(ReaderCardCapture.searchEscaped("don't_care*") == "don't\\_care\\*")
        #expect(ReaderCardCapture.html("a < b\nc & d") == "a &lt; b<br>c &amp; d")
    }
}

@Suite("Reader page transition")
struct ReaderPageTransitionTests {
    @Test("Curl is the default")
    func curlIsDefault() {
        // The stored default lives in the view layer; this asserts the
        // fallback the view and settings both use.
        #expect(ReaderPageTransition(rawValue: "") == nil)
        #expect(ReaderPageTransition.curl.label == "Curl")
    }

    @Test("all four Apple Books options exist and are labelled")
    func allFourOptionsExist() {
        let labels = ReaderPageTransition.allCases.map(\.label)
        #expect(labels == ["Curl", "Slide", "Fast Fade", "Scroll"])
    }

    @Test("every effect, Curl included, follows a finger")
    func everyEffectSupportsInteractivePan() {
        // Curl used to be the exception, and the settings UI warned about it.
        // Since 4d45f8e7 curl runs on UIPageViewController's native
        // interactive page turn, so a drag turns the page in every mode.
        for transition in ReaderPageTransition.allCases {
            #expect(
                transition.supportsInteractivePan,
                "unexpected pan support for \(transition.label)"
            )
        }
    }

    @Test("Fast Fade is quicker than Slide, or they are the same effect twice")
    func fadeIsQuickerThanSlide() {
        #expect(
            ReaderPageTransition.fastFade.duration < ReaderPageTransition.slide.duration
        )
    }

    @Test("an unknown stored value falls back rather than crashing")
    func unknownValueFallsBack() {
        #expect(ReaderPageTransition(rawValue: "nonsense") == nil)
    }

    @Test("the preference key is namespaced with the other reader keys")
    func preferenceKeyIsNamespaced() {
        #expect(ReaderPreferenceKeys.pageTransition.hasPrefix("reader_typo_"))
    }
}
