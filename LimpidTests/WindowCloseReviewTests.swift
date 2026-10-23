// WindowCloseReviewTests.swift
// Limpid — the review a closed window leaves its project, and its undo toast.

import Foundation
import Testing
@testable import Limpid

/// The review a closed window leaves its project, and its undo toast.
extension WindowCloseTests {
    @Test func aClosedWindowsUnsavedComment_isParked_andComesBackToTheNextWindowToShowTheProject() throws {
        let fixture = try Fixture()
        let (tab, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.other.review = tab
        let review = fixture.other.writeComment()
        let composer = review.composer
        fixture.other.hunkDiscards[hunk] = ProjectWindowsFixture.discarded

        fixture.close(fixture.other)
        #expect(fixture.registry.parkedReviews[fixture.second.id]?.tab?.review == tab)

        // The primary switches to the project in place and takes it.
        let reopened = try fixture.chooseSecond(in: fixture.primary)

        #expect(reopened === fixture.primary)
        #expect(reopened.review == tab)
        #expect(reopened.reviewHasUnsavedComment)
        #expect(reopened.reviewSession === review)
        #expect(reopened.reviewSession?.composer == composer)
        #expect(reopened.review?.isShown == true)
        #expect(reopened.reviewPresentation.isPresented)
        #expect(reopened.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
        #expect(fixture.registry.parkedReviews.isEmpty)
        // The window comes back where it was in the project, too.
        #expect(reopened.selection.activeTabID == fixture.secondTab.id)
    }

    @Test func aClosedWindowsUndoToast_movesToTheWindowLeft() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)
        var tookBack = false
        let restore = ToastItem(.codeRestored(turnNumber: 3)) { tookBack = true }
        toasts.show(restore, in: fixture.other.id)

        fixture.close(fixture.other)

        #expect(toasts.current(in: fixture.other.id) == nil)
        #expect(toasts.current(in: fixture.primary.id)?.id == restore.id)
        toasts.undo(in: fixture.primary.id)
        #expect(tookBack)
    }

    @Test func theClosedToast_doesNotCoverAnUndoToastInTheWindowLeft() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)
        let restore = ToastItem(.codeRestored(turnNumber: 3)) {}
        toasts.show(restore, in: fixture.primary.id)

        fixture.close(fixture.other)

        #expect(toasts.current(in: fixture.primary.id)?.id == restore.id)
    }

    @Test func aClosedWindow_isMarkedClosed_andHoldsNoReview() throws {
        let fixture = try Fixture()
        let closed = fixture.other

        fixture.close(closed)

        #expect(closed.isClosed)
        #expect(!fixture.primary.isClosed)
        #expect(closed.review == nil)
        #expect(closed.reviewSession == nil)
    }

    @Test func theSameReadingAskedForAgain_keepsTheComment_forTheParkedTab() throws {
        let fixture = try Fixture()
        let (tab, _) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.other.review = tab
        let review = fixture.other.writeComment()
        // The same range opened again (⌘J to the same turn) while the
        // comment is written: not refused, and the comment stays, in the
        // review the tab keeps.
        var again = tab
        again.isShown = true
        #expect(!ReviewTabModel.refusesReplacing(fixture.other.review, with: again, hasUnsavedComment: true))

        fixture.close(fixture.other)

        #expect(fixture.registry.parkedReviews[fixture.second.id]?.tab?.session === review)
        #expect(review.composer.text == "Why this?")
    }

    @Test func aMovedUndoToast_replacesNewsInTheWindowLeft() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)
        toasts.show(ToastItem(message: .verbatim("News"), undo: nil), in: fixture.primary.id)
        let moving = ToastItem(.codeRestored(turnNumber: 4)) {}
        toasts.show(moving, in: fixture.other.id)

        fixture.close(fixture.other)

        #expect(toasts.current(in: fixture.primary.id)?.id == moving.id)
    }

    @Test func withAnUndoToastInBothWindows_theOneInTheWindowLeftStays() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)
        let kept = ToastItem(.codeRestored(turnNumber: 3)) {}
        let moving = ToastItem(.codeRestored(turnNumber: 4)) {}
        toasts.show(kept, in: fixture.primary.id)
        toasts.show(moving, in: fixture.other.id)

        fixture.close(fixture.other)

        #expect(toasts.current(in: fixture.primary.id)?.id == kept.id)
        #expect(toasts.current(in: fixture.other.id) == nil)
    }

    @Test func aClosedWindowsReviewWithoutAComment_closes_butKeepsItsDiscards() throws {
        let fixture = try Fixture()
        let (tab, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.other.review = tab
        fixture.other.hunkDiscards[hunk] = ProjectWindowsFixture.discarded

        fixture.close(fixture.other)
        #expect(fixture.registry.parkedReviews[fixture.second.id]?.tab == nil)
        let reopened = try fixture.chooseSecond(in: fixture.primary)

        #expect(reopened.review == nil)
        #expect(!reopened.reviewPresentation.isPresented)
        #expect(reopened.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
    }

    @Test func aDiscardedHunk_staysMarkedAfterItsWindowClosed() throws {
        let fixture = try Fixture()
        let (_, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        let closed = fixture.other
        closed.hunkDiscards[hunk] = .running

        fixture.close(closed)
        // The discard ends after its window closed, written through the
        // window it began in, as its task holds it.
        closed.hunkDiscards[hunk] = ProjectWindowsFixture.discarded
        let reopened = try fixture.chooseSecond(in: fixture.primary)

        #expect(reopened.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
        // An undo ending later lands in the same place.
        closed.hunkDiscards[hunk] = nil
        #expect(reopened.hunkDiscards[hunk] == nil)
    }
}
