import Testing
@testable import AmgiUI

/// Copy derivations for the Library triage card. Engine-free by design —
/// `DeckTriageItem.subtitle` formats the classifier's output, the way
/// `HeroData`'s derivations format the hero's.
@Suite("DeckTriageItem")
struct DeckTriageItemTests {
    private func item(
        new: Int = 0,
        learn: Int = 0,
        review: Int = 0,
        issue: DeckTriageIssue
    ) -> DeckTriageItem {
        DeckTriageItem(
            row: DeckRowViewData(
                id: 7, name: "한국어", fullName: "Languages::한국어",
                newCount: new, learnCount: learn, reviewCount: review,
                isFiltered: false, subdeckCount: 0
            ),
            issue: issue
        )
    }

    @Test func neglectedSubtitleCountsTotalDue() {
        #expect(item(new: 12, learn: 8, review: 42, issue: .neglected(daysAgo: 47)).subtitle
            == "Not studied in 47 days · 62 due")
    }

    @Test func neglectedWithoutWindowReadsOverAYear() {
        #expect(item(review: 200, issue: .neglected(daysAgo: nil)).subtitle
            == "Not studied in over a year · 200 due")
    }

    @Test func neverStartedSubtitleCountsNew() {
        #expect(item(new: 340, issue: .neverStarted).subtitle == "Never started · 340 new")
    }

    @Test func newBacklogSubtitleProjectsWeeks() {
        #expect(item(new: 412, issue: .newBacklog(perDay: 20, daysToClear: 21)).subtitle
            == "412 new · about 3 weeks at 20/day")
    }

    @Test func emptySubtitle() {
        #expect(item(issue: .empty).subtitle == "Nothing due · never reviewed")
    }

    @Test func parkedSubtitleCountsDaysParked() {
        #expect(item(issue: .parked(daysAgo: 129)).subtitle == "Parked 129 days ago · all cards suspended")
    }

    @Test func parkedWithoutWindowOmitsAge() {
        #expect(item(issue: .parked(daysAgo: nil)).subtitle == "Parked · all cards suspended")
    }

    @Test func identityFollowsRow() {
        #expect(item(issue: .empty).id == 7)
    }
}

@Suite("DeckTriageData")
struct DeckTriageDataTests {
    @Test func hidesOnlyWhenResolvedAndEmpty() {
        #expect(DeckTriageData.resolvedEmpty.isHidden)
        #expect(!DeckTriageData.unresolved.isHidden)
        #expect(!DeckTriageData.sample.isHidden)
    }
}
