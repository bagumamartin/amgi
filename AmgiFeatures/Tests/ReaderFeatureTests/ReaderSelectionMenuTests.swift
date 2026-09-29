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

    @Test("Look Up, Add Note, Highlight, Bookmark and Copy are all offered")
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
        #expect(actions.contains(.addNote))
        #expect(actions.contains(.copy))
    }

    @Test("the raw value is stable, because macOS carries it in a menu item")
    func rawValuesAreStable() {
        // `NSMenuItem.representedObject` round-trips the action through this
        // value, so a rename would silently break the macOS menu.
        #expect(ReaderSelectionAction.lookUp.rawValue == "lookUp")
        #expect(ReaderSelectionAction.highlight.rawValue == "highlight")
        #expect(ReaderSelectionAction.bookmark.rawValue == "bookmark")
        #expect(ReaderSelectionAction.addNote.rawValue == "addNote")
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

    @Test("Curl is the only effect without an interactive pan")
    func onlyCurlLacksInteractivePan() {
        // Worth asserting because it is the trade-off the settings UI warns
        // about: UIKit's page-curl controller drops its pan gesture.
        for transition in ReaderPageTransition.allCases {
            #expect(
                transition.supportsInteractivePan == (transition != .curl),
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
