import Testing
@testable import AnkiKit

/// These names are written into the user's collection and re-read after a
/// relaunch to clean up a session deck left behind by a crash. The predicate
/// has to hold on the exact strings the app writes, forever — so it is pinned
/// here rather than left to three call sites that each spelled it out.
@Suite struct StudyDeckNamingTests {

    @Test func sessionDecksAreRecognizedByName() {
        #expect(StudyDeckNaming.isSessionDeck(StudyDeckNaming.sessionName(token: "ab12cd34")))
        #expect(StudyDeckNaming.isSessionDeck(StudyDeckNaming.legacySelectionName))
        #expect(!StudyDeckNaming.isSessionDeck("Study"))
        // A user deck whose name merely ends with the token is not ours.
        #expect(!StudyDeckNaming.isSessionDeck("Korean::Deck::Study · Session · ab12cd34"))
    }

    @Test func onlyOurOwnDecksCountAsTemporary() {
        #expect(StudyDeckNaming.isTemporarySessionDeck(StudyDeckNaming.sessionName(token: "ab12cd34")))
        #expect(StudyDeckNaming.isTemporarySessionDeck(StudyDeckNaming.customStudyName))
        // A filtered deck the user made by hand has to survive: the cleanup
        // pass deletes without asking.
        #expect(!StudyDeckNaming.isTemporarySessionDeck("Spanish::Medicine"))
        #expect(!StudyDeckNaming.isTemporarySessionDeck("Study · Sessions"))
    }

    @Test func theSessionNameIsDistinctPerSitting() {
        #expect(
            StudyDeckNaming.sessionName(token: "aaaaaaaa")
                != StudyDeckNaming.sessionName(token: "bbbbbbbb")
        )
    }
}
