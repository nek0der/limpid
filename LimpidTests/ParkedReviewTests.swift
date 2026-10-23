// ParkedReviewTests.swift
// Limpid — a project's review tab, kept while its window shows another project and given back as it was.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

/// A window switching to another project in place leaves its review tab with
/// the project it reads, whether or not a comment is being written in it, and
/// a window showing the project again takes it back as it was: its discards,
/// its comment, where it stood, how it was laid out, and what its view held.
/// No review of another project replaces it, and no comment kept for a
/// project is dropped for another.
@MainActor
struct ParkedReviewTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - Kept by switching

    @Test func aReviewWithoutAComment_goesWithItsProjectAsTheWindowSwitches_withItsDiscards() throws {
        let fixture = Fixture()
        let (tab, hunk) = try Fixture.reviewAndHunk()
        fixture.primary.review = tab
        fixture.primary.hunkDiscards[hunk] = Fixture.discarded

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewPresentation.isPresented)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == tab.opening)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.session?.holdsComment != true)
        // The worktree's records are the worktree's: they stay where every
        // window reads them.
        #expect(fixture.registry.reviewDiscards.hunkDiscards[hunk] == Fixture.discarded)
    }

    @Test func aParkedReview_comesBackWithItsProject_withItsDiscardedHunks() throws {
        let fixture = Fixture()
        let (tab, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.primary.review = tab
        fixture.primary.hunkDiscards[hunk] = ProjectWindowsFixture.discarded

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.primary.review == nil)
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == true)
        #expect(fixture.primary.reviewPresentation.isPresented)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.primary.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func aParkedReview_comesBackWithItsComment_andItsDiscards() throws {
        let fixture = Fixture()
        let tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary)
        let hunk = try ProjectWindowsFixture.reviewAndHunk().hunk
        fixture.primary.hunkDiscards[hunk] = ProjectWindowsFixture.discarded
        let review = try #require(fixture.primary.reviewSession)
        let composer = review.composer

        fixture.choose(fixture.bTab, in: fixture.primary)
        // `b`'s own review opens and closes meanwhile.
        fixture.primary.review = try ProjectWindowsFixture.review()
        fixture.primary.letGoOfReview()
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        // The review the tab kept, with the comment as it was typed.
        #expect(fixture.primary.reviewSession === review)
        #expect(review.composer == composer)
        #expect(fixture.primary.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
    }

    @Test func aReviewWithACommentBeingWritten_isKeptForTheProjectLeft_andAnotherOpensInTheNext() throws {
        let fixture = Fixture()
        let tab = try Fixture.windowWritingAComment(fixture.primary)

        fixture.choose(fixture.bTab, in: fixture.primary)

        // The window holds nothing of `a`: a review of `b` opens there.
        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.primary.reviewSession == nil)
        let next = try Fixture.review()
        #expect(!ReviewTabModel.refusesReplacing(
            fixture.primary.review,
            with: next,
            hasUnsavedComment: fixture.primary.reviewHasUnsavedComment
        ))
        let parked = try #require(fixture.registry.parkedReviews[fixture.a.id])
        #expect(parked.tab?.review.opening == tab.opening)
        #expect(parked.tab?.session?.composer.text == "Why this?")
        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
    }

    @Test func aWindowClosedAfterSwitching_leavesTheReviewWithTheProjectItWasWrittenIn() throws {
        let fixture = Fixture()
        _ = try fixture.window(showing: fixture.c)
        let tab = try Fixture.windowWritingAComment(fixture.primary)
        fixture.choose(fixture.bTab, in: fixture.primary)

        fixture.registry.close(fixture.primary.id, in: fixture.session)

        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == tab.opening)
    }

    @Test func aCommentKept_throughQuickSwitchesThereAndBack() throws {
        let fixture = Fixture()
        _ = try ProjectWindowsFixture.windowWritingAComment(fixture.primary)
        let review = try #require(fixture.primary.reviewSession)

        // A to B and back to A at once, twice.
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.choose(fixture.aTab, in: fixture.primary)
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.reviewSession === review)
        #expect(review.composer.text == "Why this?")
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func aParkedReviewsStack_readsAgainAsItsTabComesBack() throws {
        let fixture = Fixture()
        fixture.primary.review = try ProjectWindowsFixture.review()
        let review = ProjectWindowState.reviewSession(root: "/repo")
        fixture.primary.reviewSession = review

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(review.stackLoader.isReleased)
        fixture.choose(fixture.aTab, in: fixture.primary)

        // Before its list is read again, which may fail or be overtaken.
        #expect(!review.stackLoader.isReleased)
    }

    @Test func aReviewParkedBySwitching_comesBackAsItWasLeft() throws {
        let fixture = Fixture()
        let window = fixture.primary
        var tab = try ProjectWindowsFixture.review()
        tab.isShown = false
        window.review = tab
        let read = ReviewTabModel.OutsideTurnsRead(opening: tab.opening, listReads: 2, counted: ["a.swift": "blob:1"], listed: ["a.swift"])
        window.reviewOutsideTurnsRead = read
        window.reviewPresentation.diffLayout = .sideBySide
        window.reviewPresentation.railWidth = 300
        var view = ReviewTabViewState()
        view.isTreeLayout = true
        view.hidesViewedFiles = true
        view.fileFilter = "src"
        view.collapsedSections = ["dir:src"]
        view.search = ReviewSearch(query: "TODO", isPresented: true, index: 2)
        view.areEarlierCommentsExpanded = true
        window.reviewTabView = view

        fixture.choose(fixture.bTab, in: window)
        #expect(window.reviewTabView == ReviewTabViewState())
        // `b`'s review is read in its own way meanwhile.
        window.reviewPresentation.diffLayout = .unified
        window.reviewPresentation.railWidth = 200
        fixture.choose(fixture.aTab, in: window)

        // Behind as it was left, and kept by the switch that brought it back:
        // `ParkedReviewArrivalTests`.
        #expect(window.review?.opening == tab.opening)
        #expect(window.reviewOutsideTurnsRead == read)
        #expect(window.reviewPresentation.diffLayout == .sideBySide)
        #expect(window.reviewPresentation.railWidth == 300)
        #expect(window.reviewTabView == view)
    }

    @Test func theBandOfATabThatCameBack_waitsAgainBeforeAKeyPressCounts() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let tab = try ProjectWindowsFixture.review()
        window.review = tab
        let shown = Self.band(of: tab)
        window.reviewBandGate.noteShown(shown, at: SuspendingClock().now - .seconds(5))

        fixture.choose(fixture.bTab, in: window)
        fixture.choose(fixture.aTab, in: window)
        // Nothing is on screen until the band is drawn again, after the
        // review has read its list.
        #expect(window.reviewBandGate.decide(at: SuspendingClock().now + .seconds(10)) == nil)
        let back = SuspendingClock().now
        ReviewTabActions.noteBandShown(shown, of: tab.opening, window: window)

        #expect(window.reviewBandGate.decide(at: back) == nil)
        #expect(window.reviewBandGate.decide(at: back + .seconds(1)) != nil)
    }

    @Test func theBandOfTheTabLeft_doesNotSpeakForTheTabTaken() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let tab = try ProjectWindowsFixture.review()
        window.review = tab
        fixture.choose(fixture.bTab, in: window)
        let left = try ProjectWindowsFixture.review()
        window.review = left

        fixture.choose(fixture.aTab, in: window)
        // `a`'s band is drawn, then `b`'s goes.
        ReviewTabActions.noteBandShown(Self.band(of: tab), of: tab.opening, window: window)
        ReviewTabActions.noteBandShown(nil, of: left.opening, window: window)

        #expect(window.reviewBandGate.decide(at: SuspendingClock().now + .seconds(1)) != nil)
    }

    /// The band of `tab` with "Mark as Viewed" through `T7`.
    private static func band(of tab: ReviewTabState) -> ReviewBandGate.Shown {
        ReviewBandGate.Shown(
            opening: tab.opening,
            selection: tab.selection,
            action: .throughTurn(ReviewTabTurn(id: TurnID("T7"), number: 7))
        )
    }

    // MARK: - Another project's review

    @Test func openingAReviewInAnotherProject_doesNotReplaceTheParkedOne() throws {
        let fixture = Fixture()
        let mine = try ProjectWindowsFixture.review()
        fixture.primary.review = mine
        fixture.choose(fixture.bTab, in: fixture.primary)

        // A review opens in `b`.
        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)
        #expect(fixture.primary.review == nil)
        let theirs = try ProjectWindowsFixture.review()
        fixture.primary.review = theirs

        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == mine.opening)
        fixture.choose(fixture.aTab, in: fixture.primary)
        #expect(fixture.primary.review?.opening == mine.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == theirs.opening)
        #expect(fixture.registry.parkedReviews[fixture.a.id] == nil)
    }

    @Test func aReviewParkedBySwitching_isProtectedFromTheSweep() throws {
        let fixture = Fixture()
        let tab = try ProjectWindowsFixture.review()
        fixture.primary.review = tab
        guard case let .turns(range) = tab.scope else { throw CancellationError() }

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review == nil)
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session) == [range])
    }

    /// Removing the project closes the review kept for it, whether or not
    /// a comment was being written in it.
    @Test(arguments: [false, true])
    func removingAProject_closesItsParkedReview(isWritingAComment: Bool) throws {
        let fixture = Fixture()
        if isWritingAComment {
            _ = try ProjectWindowsFixture.windowWritingAComment(fixture.primary)
        } else {
            fixture.primary.review = try ProjectWindowsFixture.review()
        }
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab != nil)
        #expect(!fixture.registry.reviewTurnRanges(in: fixture.session).isEmpty)

        fixture.session.removeProject(fixture.a.id)
        // As the app does when the projects change.
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).isEmpty)
        #expect(fixture.primary.review == nil)
    }

    // MARK: - Comments that meet

    /// A comment kept for `b` by a window that closed on it, and the primary
    /// on `b` with a comment of its own, in a review of a scratch pane: the
    /// primary does not take `b`'s tab as it arrives.
    private static func twoComments(_ fixture: Fixture) throws -> TwoComments {
        let other = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let kept = try ProjectWindowsFixture.windowWritingAComment(other)
        fixture.registry.close(other.id, in: fixture.session)
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let own = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
        return TwoComments(kept: kept, own: own, scratch: scratch)
    }

    /// `b`'s kept comment, the primary's own, and the scratch tab of its pane.
    @MainActor
    private struct TwoComments {
        let kept: ReviewTabState
        let own: ReviewTabState
        let scratch: Tab
    }

    @Test func aWindowLeavingWithItsOwnComment_keepsIt_andTheProjectKeepsItsOwn() throws {
        let fixture = Fixture()
        let comments = try Self.twoComments(fixture)
        let (kept, own, scratch) = (comments.kept, comments.own, comments.scratch)
        // The scratch pane closes: the review keeps the owner it opened
        // with, the window, and goes with no project.
        fixture.session.closeTab(scratch.id)

        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        let parked = try #require(fixture.registry.parkedReviews[fixture.b.id])
        #expect(parked.tabs.map(\.review.opening) == [kept.opening])
        #expect(parked.tabs.map { $0.session?.holdsComment == true } == [true])
    }

    @Test func leavingAReviewWithAComment_takesTheOneTheNextProjectKept() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let kept = try Fixture.windowWritingAComment(other)
        fixture.registry.close(other.id, in: fixture.session)
        let mine = try Fixture.windowWritingAComment(fixture.primary)

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == kept.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == mine.opening)
    }

    @Test func twoCommentsThatMet_areBothKept_eachWhereItComesBack() throws {
        let fixture = Fixture()
        let comments = try Self.twoComments(fixture)
        let (kept, own) = (comments.kept, comments.own)
        let third = try fixture.window(showing: fixture.c)

        // The primary closes on `b`, with its own scratch pane's comment:
        // `b` keeps its tab, and the scratch row the primary's.
        fixture.registry.close(fixture.primary.id, in: fixture.session)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tabs.map(\.review.opening) == [kept.opening])
        #expect(fixture.registry.parkedScratchReview?.tabs.map(\.review.opening) == [own.opening])
        // Both kept out of the sweep while they wait.
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).count == 2)

        fixture.choose(fixture.bTab, in: third)
        #expect(third.review?.opening == kept.opening)
        #expect(third.reviewHasUnsavedComment)

        // That comment is done with, and the window goes to the scratch
        // row: the other comes, behind, with its comment.
        third.letGoOfReview()
        fixture.arriveAtTheScratchRow(third)

        #expect(third.review?.opening == own.opening)
        #expect(third.review?.isShown == false)
        #expect(third.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    @Test func theTabsAProjectKeeps_neverDropOneWithAComment() throws {
        let fixture = Fixture()
        let window = fixture.primary
        func tab(hasComment: Bool) throws -> ParkedReview.Tab {
            window.review = try ProjectWindowsFixture.review()
            window.reviewSession = nil
            if hasComment {
                window.writeComment()
            }
            return try #require(ParkedReview.Tab(leftBy: window, kept: .always))
        }
        let plain = try tab(hasComment: false)
        let plainEarlier = try tab(hasComment: false)
        let written = try tab(hasComment: true)
        let writtenEarlier = try tab(hasComment: true)
        let openings = { (tabs: [ParkedReview.Tab]) in tabs.map(\.review.opening) }

        // The one left last, of two plain ones.
        #expect(openings(ParkedReview.tabs(plain, joining: [plainEarlier])) == [plain.review.opening])
        #expect(openings(ParkedReview.tabs(written, joining: [plainEarlier])) == [written.review.opening])
        #expect(openings(ParkedReview.tabs(plain, joining: [writtenEarlier])) == [writtenEarlier.review.opening])
        #expect(openings(ParkedReview.tabs(written, joining: [writtenEarlier]))
            == [written.review.opening, writtenEarlier.review.opening])
        #expect(openings(ParkedReview.tabs(nil, joining: [writtenEarlier])) == [writtenEarlier.review.opening])
        #expect(ParkedReview.tabs(nil, joining: []).isEmpty)
        // A closing window keeps a tab only with a comment; a scratch pane's
        // review none.
        window.letGoOfComment()
        #expect(ParkedReview.Tab(leftBy: window, kept: .withComment) == nil)
        window.writeComment()
        #expect(ParkedReview.Tab(leftBy: window, kept: .withComment) != nil)
        // A comment set aside in the banner counts until it is let go of.
        window.reviewSession?.setComposerAside()
        #expect(ParkedReview.Tab(leftBy: window, kept: .withComment)?.session?.holdsComment == true)
        #expect(ParkedReview.Tab(leftBy: window, kept: .none) == nil)
    }

    // MARK: - Arriving with a review of the window's own

    /// `b`'s tab, with a comment, kept as a window closed on it; the
    /// primary, on `a`, reviewing a scratch pane.
    private static func scratchReviewMeetsAKeptTab(_ fixture: Fixture, hasComment: Bool) throws -> ReviewTabState {
        let other = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let kept = try ProjectWindowsFixture.windowWritingAComment(other)
        fixture.registry.close(other.id, in: fixture.session)
        try fixture.reviewAScratchPane(hasComment: hasComment)
        return kept
    }

    @Test func arrivingWithAScratchReviewWithoutAComment_takesTheProjectsTab() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: false)

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == kept.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
        // The scratch pane's discards are its worktree's, still there.
        #expect(fixture.primary.hunkDiscards[Fixture.scratchHunk] == ProjectWindowsFixture.discarded)
    }

    @Test func arrivingWithAScratchReviewWithAComment_keepsIt_andLeavesTheProjectsTabKept() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: true)
        let own = fixture.primary.review

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review == own)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
    }

    // MARK: - Opening in a project that keeps a tab

    @Test func openingAReview_bringsTheProjectsTabFirst() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: true)
        fixture.choose(fixture.bTab, in: fixture.primary)
        // The scratch pane's comment is saved or thrown away.
        fixture.primary.letGoOfComment()

        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)

        #expect(fixture.primary.review?.opening == kept.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.primary.hunkDiscards[Fixture.scratchHunk] == ProjectWindowsFixture.discarded)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func openingAReview_whileTheWindowsOwnHoldsAComment_takesNothing() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: true)
        fixture.choose(fixture.bTab, in: fixture.primary)
        let own = fixture.primary.review

        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)

        #expect(fixture.primary.review == own)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
    }

    @Test func openingAReviewOnAScratchTab_leavesTheProjectsTabKept() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: true)
        fixture.choose(fixture.bTab, in: fixture.primary)
        let own = fixture.primary.review
        fixture.primary.letGoOfComment()
        let scratch = try #require(fixture.session.tabs.first { $0.container == .loose })
        fixture.choose(scratch, in: fixture.primary)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)

        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)

        #expect(fixture.primary.review == own)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
    }

    // MARK: - Closing

    @Test func aTabBehindAsItsWindowClosed_comesBackBehind() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        var tab = try ProjectWindowsFixture.windowWritingAComment(other)
        tab.isShown = false
        other.review = tab

        fixture.registry.close(other.id, in: fixture.session)
        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        #expect(fixture.primary.reviewHasUnsavedComment)
    }

    // MARK: - A view that went

    @Test func aViewThatWent_readsNoScopeOfTheNextTab() {
        let first = UUID()
        let next = UUID()
        // Its task is canceled as it goes, whatever the window draws.
        #expect(!ReviewViewWork.goesOn(begunFor: first, drawing: first, isCancelled: true))
        // Its reads end with another tab drawn: that tab's scope is its own
        // review's.
        #expect(!ReviewViewWork.goesOn(begunFor: first, drawing: next, isCancelled: false))
        #expect(ReviewViewWork.goesOn(begunFor: first, drawing: first, isCancelled: false))
    }
}
