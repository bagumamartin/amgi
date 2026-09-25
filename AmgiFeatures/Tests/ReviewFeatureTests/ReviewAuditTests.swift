import Foundation
import Testing
import SwiftUI
import AnkiKit
import AmgiAppCore
import AmgiReviewCore
@testable import ReviewFeature

@Suite("Review audit regressions")
struct ReviewAuditTests {
    @Test("scheduler coordinator grants one serialized profile lease")
    @MainActor
    func schedulerLeaseIsExclusiveAndSerialized() throws {
        let coordinator = ReviewSessionCoordinator()
        let firstProfile = Self.profile(id: "default", selectionID: UUID())
        let secondProfile = Self.profile(id: "default", selectionID: UUID())
        let lease = try coordinator.acquireSession(
            sessionID: UUID(),
            profile: firstProfile
        )

        #expect(coordinator.hasActiveSession)
        #expect(throws: ReviewSessionLeaseError.alreadyActive(lease.identity)) {
            try coordinator.acquireSession(sessionID: UUID(), profile: firstProfile)
        }
        #expect(throws: ReviewSessionLeaseError.alreadyActive(lease.identity)) {
            try coordinator.acquireSession(sessionID: UUID(), profile: secondProfile)
        }

        #expect(coordinator.beginMutation(for: lease))
        #expect(!coordinator.beginMutation(for: lease))
        coordinator.releaseSession(lease) // Must not revoke an in-flight operation.
        #expect(coordinator.activeSession == lease.identity)
        coordinator.endMutation()
        coordinator.releaseSession(lease)
        #expect(coordinator.activeSession == nil)
    }

    @Test("profile drain revokes an idle lease for the next activation")
    @MainActor
    func drainRevokesLease() async throws {
        let coordinator = ReviewSessionCoordinator()
        _ = try coordinator.acquireSession(
            sessionID: UUID(),
            profile: Self.profile(id: "work", selectionID: UUID())
        )
        #expect(coordinator.hasActiveSession)

        await coordinator.drain()
        #expect(coordinator.activeSession == nil)
        #expect(throws: ReviewSessionLeaseError.draining) {
            try coordinator.acquireSession(
                sessionID: UUID(),
                profile: Self.profile(id: "work", selectionID: UUID())
            )
        }
        coordinator.endDrain()

        let replacement = try coordinator.acquireSession(
            sessionID: UUID(),
            profile: Self.profile(id: "work", selectionID: UUID())
        )
        #expect(coordinator.activeSession == replacement.identity)
    }

    @Test("live counts clear only for their owning session")
    @MainActor
    func liveCountClearIsOwnerScoped() {
        let counts = LiveReviewCounts()
        let owner = UUID()
        let staleWindow = UUID()
        let snapshot = DeckCounts(newCount: 1, learnCount: 2, reviewCount: 3)
        counts.publish(sessionID: owner, baseline: .zero, live: snapshot)

        counts.clear(sessionID: staleWindow)
        #expect(counts.snapshot != nil)
        counts.clear(sessionID: owner)
        #expect(counts.snapshot == nil)
    }

    @Test("duplicate validation permits phase-disjoint keys and rejects real collisions")
    func duplicateShortcutValidation() {
        #expect(ReviewShortcutAction.duplicateConflicts(in: [:]).isEmpty)

        let bindings = [
            ReviewShortcutAction.rateGood.rawValue: ReviewShortcut(key: "1", modifiers: [])
        ]
        let conflict = ReviewShortcutAction.duplicateConflicts(in: bindings)
        #expect(conflict.contains(ReviewShortcutConflict(first: .rateAgain, second: .rateGood)))
        #expect(
            ReviewShortcutAction.conflictingAction(
                for: ReviewShortcut(key: "1", modifiers: []),
                action: .rateEasy,
                in: bindings
            ) == .rateAgain
        )

        // Reveal (question) and repeat-last (answer) deliberately share Space.
        let phaseSpecific = [
            ReviewShortcutAction.revealAnswer.rawValue: ReviewShortcut(key: " ", modifiers: []),
            ReviewShortcutAction.repeatLastRating.rawValue: ReviewShortcut(key: " ", modifiers: [])
        ]
        #expect(ReviewShortcutAction.duplicateConflicts(in: phaseSpecific).isEmpty)
    }

    @Test("shortcut signatures normalize case and arrow aliases")
    func shortcutValidationNormalization() {
        #expect(
            ReviewShortcut(key: "A", modifiers: .command).validationSignature
                == ReviewShortcut(key: "a", modifiers: .command).validationSignature
        )
        #expect(
            ReviewShortcut(key: "↑", modifiers: [.command, .shift]).validationSignature
                == ReviewShortcut(key: "\u{F700}", modifiers: [.command, .shift]).validationSignature
        )
    }

    @Test("macOS lookup bootstrap filters controls and remains available to prewarm")
    @MainActor
    func macLookupBootstrapContract() {
        let script = CardWebView.tapLookupBootstrapJS
        #expect(script.contains("interactiveTarget(target)"))
        #expect(script.contains("amgiCardLookupPayloadAt"))
        #expect(script.contains("window.getSelection()"))
        #expect(script.contains("amgiCardState().isAnswerSide"))
        #expect(script.contains("data-amgi-interactive"))
        #expect(script.contains("amgiLookupText"))
    }

    @Test("native card images get a useful side-aware accessibility label")
    @MainActor
    func nativeImageAccessibilityLabel() {
        #expect(
            NativeCardView.imageAccessibilityLabel(for: "cat-photo_01.jpg")
                == "Question card image: cat photo 01"
        )
        #expect(
            NativeCardView.imageAccessibilityLabel(for: "", isAnswerSide: true)
                == "Answer card image"
        )
    }

    @Test("wide review controls retain finite layout limits")
    func wideReviewLayoutIsBounded() {
        #expect(ReviewLayoutMetrics.contentMaxWidth < 1_000)
        #expect(ReviewLayoutMetrics.compactRatingMaxWidth < ReviewLayoutMetrics.contentMaxWidth)
        #expect(ReviewLayoutMetrics.macRatingMaxWidth < ReviewLayoutMetrics.contentMaxWidth)
    }

    private static func profile(id: String, selectionID: UUID) -> ProfileContext {
        ProfileContext(id: id, displayName: id, selectionID: selectionID)
    }
}
