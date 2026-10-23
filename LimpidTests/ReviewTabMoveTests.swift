// ReviewTabMoveTests.swift
// Limpid — a review whose agent's tab is dragged to another row follows it, as its window switches or while it is kept.

import Foundation
import Testing
@testable import Limpid

/// Where a review goes once its agent's tab has moved between the scratch
/// row and a project's rows: by the row the pane is on now, as its strip
/// shows it, and by the owner it was opened with only once the pane is
/// gone. A kept tab is sorted out again before any window takes one, so a
/// window takes only what its strip can show, and no comment is dropped.
@MainActor
struct ReviewTabMoveTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - A tab moved to another row, as its window switches

    /// A scratch pane's review with a comment being written in it, whose
    /// tab is then dragged to `c`'s row, the window standing on `aTab` or
    /// on the scratch row: its strip shows the tab only on `c` now, so the
    /// review goes with `c` as the window leaves for `b`, rather than stay
    /// in a window that can no longer show it and refuse every other review
    /// for its comment.
    @Test(arguments: [false, true])
    func aScratchTabMovedToAProject_takesItsReviewToThatProject_asTheWindowSwitches(isOnScratchRow: Bool) throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        if isOnScratchRow {
            fixture.choose(scratch, in: fixture.primary)
        }
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.review?.opening == tab.opening)

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        // A review of `b`'s worktree opens there.
        let inB = try ProjectWindowsFixture.review()
        let next = ReviewTabState(
            root: "/b",
            selection: inB.selection,
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(!ReviewTabModel.refusesReplacing(
            fixture.primary.review,
            with: next,
            hasUnsavedComment: fixture.primary.reviewHasUnsavedComment
        ))
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
        #expect(fixture.registry.parkedReviews[fixture.a.id] == nil)
        #expect(fixture.registry.parkedScratchReview == nil)

        // A window coming to show `c` brings the comment back.
        let onC = try fixture.window(showing: fixture.c)
        #expect(onC.review?.opening == tab.opening)
        #expect(onC.reviewHasUnsavedComment)
        #expect(onC.reviewSession?.composer.text == "Why this?")
        #expect(fixture.registry.parkedReviews[fixture.c.id] == nil)
    }

    /// The other way: a project's tab under review dragged to the scratch
    /// row is no project's now, and every window shows the scratch tabs,
    /// so its review stays with the window as a scratch pane's does, even
    /// with nothing written in it.
    @Test func aProjectsTabMovedToTheScratchRow_keepsItsReviewWithTheWindow_asItSwitches() throws {
        let fixture = Fixture()
        fixture.choose(fixture.cTab, in: fixture.primary)
        let pane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.review(agentPaneID: pane)
        fixture.primary.review = tab
        fixture.session.moveTab(fixture.cTab.id, to: .loose)
        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    /// With the agent's pane gone, the owner the review was opened with
    /// decides: a scratch pane's stays with the window.
    @Test func aScratchPanesReviewWhosePaneClosed_staysWithTheWindow_asItSwitches() throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        fixture.session.closeTab(scratch.id)
        #expect(fixture.session.tab(containing: pane) == nil)

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    /// A tab a switch brought back, behind, with nothing written in it,
    /// opened from a scratch pane whose tab is on `c`'s row now: it is
    /// `c`'s review, so the window landing on the scratch row keeps it, as
    /// the switch that brought it back never closes it, and the tab
    /// waiting for the scratch row waits on.
    @Test func aScratchTabMovedToAProject_isThatProjectsReview_asItsWindowLandsOnTheScratchRow() throws {
        let fixture = Fixture()
        let waiting = try fixture.closeWritingAScratchComment(showing: fixture.b)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == waiting.opening)
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        var own = try ProjectWindowsFixture.review(agentPaneID: pane, isOfNoProject: true)
        own.isShown = false
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))
        fixture.primary.review = own

        // The switch that brought the tab back lands on the scratch row.
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        fixture.primary.parkedReviewArrival = .at(ReviewArrival(fixture.primary.selection))
        ReviewTabActions.rowChanged(
            window: fixture.primary,
            session: fixture.session,
            windows: fixture.registry,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: fixture.primary.id, registry: fixture.registry)
        )

        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == waiting.opening)
    }

    /// Where a review kept for `c` waits once `c` is removed, its agent's
    /// tab dragged off `c` while it waited: where the pane is now, the
    /// scratch row or `b`, with its comment, rather than go with `c`.
    @Test(arguments: [false, true])
    func aTabMovedOffAProjectWhileItsReviewWaits_keepsTheReview_asTheProjectIsRemoved(toAnotherProject: Bool) throws {
        let fixture = Fixture()
        let pane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let tab = try fixture.closeAWindowOfNoProject(agentPaneID: pane, hasComment: true)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
        fixture.session.moveTab(fixture.cTab.id, to: toAnotherProject ? .project(fixture.b.id) : .loose)

        fixture.session.removeProject(fixture.c.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.registry.parkedReviews[fixture.c.id] == nil)
        let kept = toAnotherProject ? fixture.registry.parkedReviews[fixture.b.id] : fixture.registry.parkedScratchReview
        #expect(kept?.tab?.review.opening == tab.opening)
        #expect(kept?.tab?.session?.holdsComment == true)
    }

    /// A window switching to the very project its scratch tab under review
    /// was dragged to keeps the review: it is kept for that project as the
    /// window leaves, and comes back as the window arrives.
    @Test func aWindowSwitchingToTheProjectItsScratchTabMovedTo_keepsTheReview() throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))

        fixture.choose(fixture.cTab, in: fixture.primary)

        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewSession?.composer.text == "Why this?")
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    // MARK: - A tab moved while its review is kept

    /// A scratch review kept for the scratch row with its comment, as its
    /// window closed, whose agent's tab another window then drags to `c`'s
    /// row: it waits for `c` now. A window of `a` arriving at the scratch
    /// row, whose strip could not show it, does not take it, so it refuses
    /// no review there; a window coming to `c` does.
    @Test func aKeptScratchReviewWhoseTabMovesToAProject_waitsForThatProject_notTheScratchRow() throws {
        let fixture = Fixture()
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.b)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
        let scratch = try #require(tab.agentPaneID.flatMap { fixture.session.tab(containing: $0) })
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))

        fixture.arriveAtTheScratchRow(fixture.primary)

        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)

        let onC = try fixture.window(showing: fixture.c)
        #expect(onC.review?.opening == tab.opening)
        #expect(onC.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews[fixture.c.id] == nil)
    }

    /// The scratch row keeps only a tab with a comment being written in it:
    /// a review with nothing written in it, kept for `c` as its window
    /// switched, whose agent's tab moved to the scratch row, is let go of
    /// as the kept tabs are next sorted out, by a window arriving at the
    /// scratch row or as `c` is removed, rather than turn up behind
    /// whichever window arrives there.
    @Test(arguments: [false, true])
    func aKeptReviewWithNoComment_whoseTabMovedToTheScratchRow_isLetGoOf(byRemovingItsProject: Bool) throws {
        let fixture = Fixture()
        fixture.choose(fixture.cTab, in: fixture.primary)
        let pane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.review(agentPaneID: pane)
        fixture.primary.review = tab
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
        fixture.session.moveTab(fixture.cTab.id, to: .loose)

        if byRemovingItsProject {
            fixture.session.removeProject(fixture.c.id)
            fixture.registry.forgetProjectsGone(in: fixture.session)
        } else {
            fixture.arriveAtTheScratchRow(fixture.primary)
            #expect(fixture.primary.review == nil)
        }

        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).isEmpty)
    }

    // MARK: - Whose a review is now

    /// Where the agent's pane is now decides, and the owner the review was
    /// opened with only once the pane is gone, or for a review opened from
    /// no pane.
    @Test(arguments: [false, true])
    func isOfNoProjectNow_followsThePanesRow_thenTheOwner(openedFromAScratchPane: Bool) throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        let scratchPane = try #require(scratch.splitTree.allLeafIDs().first)
        let projectPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        func review(_ pane: UUID?) throws -> ReviewTabState {
            try ProjectWindowsFixture.review(agentPaneID: pane, isOfNoProject: openedFromAScratchPane)
        }

        #expect(try review(scratchPane).isOfNoProjectNow(in: fixture.session))
        #expect(try !review(projectPane).isOfNoProjectNow(in: fixture.session))
        #expect(try review(nil).isOfNoProjectNow(in: fixture.session) == openedFromAScratchPane)
        fixture.session.closeTab(scratch.id)
        #expect(try review(scratchPane).isOfNoProjectNow(in: fixture.session) == openedFromAScratchPane)
    }

    // MARK: - Where a moved tab is taken

    /// A window of `c` on another of its rows as the scratch tab under a
    /// kept review is dragged to `c`'s row: arriving on that row, holding no
    /// review, it takes the tab behind.
    @Test func aWindowArrivingOnTheRowAKeptTabMovedTo_takesItBehind() throws {
        let fixture = Fixture()
        let onC = try fixture.window(showing: fixture.c)
        let worktree = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.c.id,
            label: "w",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("c-w"),
            branchName: "w"
        ))
        let otherRow = ContainerID.worktree(projectID: fixture.c.id, worktreeID: worktree.id)
        fixture.session.openTab(container: otherRow, in: onC.id, intent: .person, selects: true)
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.b)
        let scratch = try #require(tab.agentPaneID.flatMap { fixture.session.tab(containing: $0) })
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))

        fixture.session.setActiveTab(fixture.cTab.id, in: onC.id, intent: .person)
        ReviewTabActions.rowChanged(
            window: onC,
            session: fixture.session,
            windows: fixture.registry,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: onC.id, registry: fixture.registry)
        )

        #expect(onC.review?.opening == tab.opening)
        #expect(onC.review?.isShown == false)
        #expect(onC.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    /// The kept tabs sorted out inside another window's take: the primary
    /// switching to `b` hands the moved tab to the window standing on its
    /// agent's row, and takes nothing of it itself.
    @Test func sortingOutInAnotherWindowsTake_handsTheMovedTabToTheWindowOnItsRow() throws {
        let fixture = Fixture()
        let onC = try fixture.window(showing: fixture.c)
        fixture.session.setActiveTab(fixture.cTab.id, in: onC.id, intent: .person)
        #expect(onC.review == nil)
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.b)
        let scratch = try #require(tab.agentPaneID.flatMap { fixture.session.tab(containing: $0) })
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review == nil)
        #expect(onC.review?.opening == tab.opening)
        #expect(onC.review?.isShown == false)
        #expect(onC.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    /// A moved tab joins a place that keeps a tab with a comment already:
    /// both comments stay, the one kept there first still first.
    @Test func aMovedTabJoiningATabWithAComment_keepsBothComments_theOneKeptThereFirst() throws {
        let fixture = Fixture()
        let cPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let first = try fixture.closeAWindowOfNoProject(agentPaneID: cPane, hasComment: true)
        let moved = try fixture.closeWritingAScratchComment(showing: fixture.b)
        let scratch = try #require(moved.agentPaneID.flatMap { fixture.session.tab(containing: $0) })
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))

        fixture.arriveAtTheScratchRow(fixture.primary)

        let kept = fixture.registry.parkedReviews[fixture.c.id]?.tabs ?? []
        #expect(kept.map(\.review.opening) == [first.opening, moved.opening])
        #expect(kept.allSatisfy { $0.session?.holdsComment == true })
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.primary.review == nil)
    }

    /// A tab kept for `c` whose agent's tab then closes stays kept for `c`,
    /// the last row it was known on, however the kept tabs are sorted out
    /// meanwhile, and comes back to a window coming to `c`.
    @Test func aKeptReviewWhosePaneClosed_staysWithTheProjectItWasKeptFor() throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
        fixture.session.closeTab(scratch.id)

        fixture.arriveAtTheScratchRow(fixture.primary)

        #expect(fixture.primary.review == nil)
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
        let onC = try fixture.window(showing: fixture.c)
        #expect(onC.review?.opening == tab.opening)
        #expect(onC.reviewHasUnsavedComment)
    }

    /// A window standing on `c`'s row is handed the moved tab whose agent
    /// is on that row, though another tab `c` keeps, of a row no window
    /// stands on, comes first.
    @Test func aWindowStandingOnARow_isHandedTheTabOnItsRow_whicheverTabIsFirst() throws {
        let fixture = Fixture()
        let onC = try fixture.window(showing: fixture.c)
        fixture.session.setActiveTab(fixture.cTab.id, in: onC.id, intent: .person)
        let worktree = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.c.id,
            label: "w",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("c-w"),
            branchName: "w"
        ))
        let worktreeRow = ContainerID.worktree(projectID: fixture.c.id, worktreeID: worktree.id)
        let worktreeTab = fixture.session.openTab(container: worktreeRow, in: fixture.primary.id, intent: .person, selects: false)
        let worktreePane = try #require(worktreeTab.splitTree.allLeafIDs().first)
        let unrelated = try fixture.closeAWindowOfNoProject(agentPaneID: worktreePane, hasComment: true)
        #expect(onC.review == nil)
        let moved = try fixture.closeWritingAScratchComment(showing: fixture.b)
        let scratch = try #require(moved.agentPaneID.flatMap { fixture.session.tab(containing: $0) })
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))

        fixture.arriveAtTheScratchRow(fixture.primary)

        #expect(onC.review?.opening == moved.opening)
        #expect(onC.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tabs.map(\.review.opening) == [unrelated.opening])
    }

    /// What a window arriving on `c`'s row holds or asks for already.
    enum ArrivingWith: CaseIterable, Sendable {
        /// A review of its own with a comment being written in it.
        case aComment
        /// A review on its way (⌥⌘R, still finding the repository).
        case anOpen
    }

    /// A window arriving on the row a kept tab moved to takes it only
    /// holding no review and opening none: its own comment, or the review
    /// it asked for, is the person's.
    @Test(arguments: ArrivingWith.allCases)
    func aWindowArrivingWithAReviewOfItsOwn_leavesTheMovedTabKept(_ arriving: ArrivingWith) throws {
        let fixture = Fixture()
        let onC = try fixture.window(showing: fixture.c)
        let worktree = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.c.id,
            label: "w",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("c-w"),
            branchName: "w"
        ))
        let otherRow = ContainerID.worktree(projectID: fixture.c.id, worktreeID: worktree.id)
        fixture.session.openTab(container: otherRow, in: onC.id, intent: .person, selects: true)
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.b)
        let scratch = try #require(tab.agentPaneID.flatMap { fixture.session.tab(containing: $0) })
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))
        switch arriving {
        case .aComment:
            try ProjectWindowsFixture.windowWritingAComment(onC)
        case .anOpen:
            onC.reviewOpenRequest = ReviewOpenRequest(containerID: otherRow, tabID: onC.selection.activeTabID)
        }

        fixture.session.setActiveTab(fixture.cTab.id, in: onC.id, intent: .person)
        ReviewTabActions.rowChanged(
            window: onC,
            session: fixture.session,
            windows: fixture.registry,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: onC.id, registry: fixture.registry)
        )

        #expect(onC.review?.opening != tab.opening)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
    }

    /// A tab with nothing written in it, moved to where another with
    /// nothing written in it is kept, gives way to it, as two such tabs
    /// meeting do: the one the person left there stays.
    @Test func aMovedTabWithNoComment_givesWayToTheOneKeptThere() throws {
        let fixture = Fixture()
        fixture.choose(fixture.cTab, in: fixture.primary)
        let cPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let keptThere = try ProjectWindowsFixture.review(agentPaneID: cPane)
        fixture.primary.review = keptThere
        fixture.choose(fixture.bTab, in: fixture.primary)
        let bPane = try #require(fixture.bTab.splitTree.allLeafIDs().first)
        let moved = try ProjectWindowsFixture.review(agentPaneID: bPane)
        fixture.primary.review = moved
        fixture.choose(fixture.aTab, in: fixture.primary)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == keptThere.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == moved.opening)
        fixture.session.moveTab(fixture.bTab.id, to: .project(fixture.c.id))

        fixture.arriveAtTheScratchRow(fixture.primary)

        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tabs.map(\.review.opening) == [keptThere.opening])
        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
    }

    /// The project a tab whose pane is gone was kept for is removed: a
    /// scratch pane's review waits for the scratch row with its comment,
    /// and a project's goes with the project.
    @Test(arguments: [false, true])
    func removingTheProjectAPanelessTabWasKeptFor(openedFromAScratchPane: Bool) throws {
        let fixture = Fixture()
        let tab: ReviewTabState
        if openedFromAScratchPane {
            let scratch = fixture.scratchTab()
            let pane = try #require(scratch.splitTree.allLeafIDs().first)
            tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
            fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))
        } else {
            fixture.choose(fixture.cTab, in: fixture.primary)
            let pane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
            tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane)
        }
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)

        // Its tabs go with it, the agent's among them.
        fixture.session.removeProject(fixture.c.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.registry.parkedReviews.isEmpty)
        if openedFromAScratchPane {
            #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
            #expect(fixture.registry.parkedScratchReview?.tab?.session?.holdsComment == true)
        } else {
            #expect(fixture.registry.parkedScratchReview == nil)
        }
    }
}
