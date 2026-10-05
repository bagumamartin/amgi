import Foundation

/// The names the app gives the filtered decks it creates for a study
/// sitting, and the one predicate that recognizes them.
///
/// Lives in AnkiKit because the callers straddle the package boundary:
/// `AmgiUI/Study/StudyDeckRow` reads it, and so does `ReviewFeature`'s
/// cleanup pass. AnkiKit is the only module both can see.
///
/// ## These are data, not copy
///
/// A filtered deck in Anki carries no marker of its own — `Deck.Filtered`
/// holds a search and a limit, nothing that says who created it. The only
/// handle the app has is the name it chose, and that name has to survive a
/// relaunch: a session deck left behind by a crash is cleaned up on the next
/// launch, which only works if the name still matches.
///
/// So these strings are written into the user's collection and compared
/// against from more than one screen (`ReviewView`, `StudyDeckRow`). They
/// must NOT be run through the catalog: a localized name would be rewritten
/// mid-session, would orphan the cleanup pass, and would leave
/// `isTemporarySessionDeck` unable to recognize a deck it created a minute
/// earlier.
///
/// What *is* copy is the label shown beside such a deck — "Resume session" /
/// "Extra session" — and that goes through `L10n`.
public enum StudyDeckNaming {
    /// Prefix for a per-span study session deck. The UUID suffix keeps two
    /// concurrent sittings apart.
    public static let sessionPrefix = "Study · Session · "

    /// The selection deck named in older builds. Still recognized so decks
    /// created before the rename are not orphaned.
    public static let legacySelectionName = "Study · Selection"

    /// Anki's own custom-study deck.
    ///
    /// Caveat worth knowing before this is relied on harder than it is now:
    /// the engine translates this name itself
    /// (`custom-study-custom-study-session` in
    /// `anki-upstream/ftl/core/custom-study.ftl`), so once the engine is
    /// given a real `preferred_langs` a non-English user gets a different
    /// string back and this comparison stops matching.
    ///
    /// The durable fix is to persist the deck id the engine hands back in
    /// `CustomStudyResult.sessionDeck` instead of sniffing names. Until then
    /// the consequence is bounded: the custom-study deck is not deleted when
    /// its session ends, and the user can delete it. It is never deleted by
    /// mistake.
    public static let customStudyName = "Custom Study Session"

    public static func sessionName(token: String) -> String {
        sessionPrefix + token
    }

    /// A study session deck this app opened.
    public static func isSessionDeck(_ name: String) -> Bool {
        name.hasPrefix(sessionPrefix) || name == legacySelectionName
    }

    /// Any deck the app may delete on the user's behalf once a sitting ends.
    ///
    /// Deliberately narrow: an arbitrary filtered deck the user built by hand
    /// must survive, so this never returns true for a deck the app did not
    /// create. Callers should also check `isFiltered` — every one of these
    /// names is only meaningful on a filtered deck.
    public static func isTemporarySessionDeck(_ name: String) -> Bool {
        isSessionDeck(name) || name == customStudyName
    }
}
