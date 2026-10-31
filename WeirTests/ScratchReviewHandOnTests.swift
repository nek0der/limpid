// ScratchReviewHandOnTests.swift
// Weir — where a review tab no project can keep waits, and how it comes back, its comment never dropped.

import Foundation
import Testing
@testable import Weir

/// A scratch pane's review with a comment being written in it, left by a
/// window that closes whatever project it shows, or any review left by a
/// window that shows none, waits for the scratch row, as a project's waits
/// for the project (`WindowRegistry.parkedScratchReview`). A window takes
/// it behind as it arrives at the scratch row with no comment of its own,
/// or at once when it stands there with no review at all; a review the
/// person left, even behind, is never swapped for it. A review whose
/// agent's pane is on a project's row waits for that project instead.
@MainActor
struct ScratchReviewHandOnTests {
    typealias Fixture = ProjectWindowsFixture

    /// A second window, on `project`, that stands on the scratch row.
    private static func onTheScratchRow(_ fixture: Fixture, showing project: Project) throws -> ProjectWindowState {
        let other = try fixture.window(showing: project)
        fixture.session.setActiveContainer(.loose, in: other.id, intent: .person)
        return other
    }

    /// A scratch pane's review in `window`, with nothing written in it.
    private static func scratchReview(in window: ProjectWindowState, fixture: Fixture, isShown: Bool) throws -> ReviewTabState {
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        var tab = try ProjectWindowsFixture.review(agentPaneID: pane, isOfNoProject: true)
        tab.isShown = isShown
        window.review = tab
        return tab
    }

    // MARK: - A window that closes showing a project

    @Test func aWindowOnAProjectClosingOnTheScratchRow_leavesTheTabForTheScratchRow() throws {
        let fixture = Fixture()
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c, onScratchRow: true)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
        #expect(fixture.primary.review == nil)

        fixture.arriveAtTheScratchRow(fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    @Test func switchingToTheProjectTheWindowShowed_doesNotTakeTheTab() throws {
        let fixture = Fixture()
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c, onScratchRow: true)

        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)

        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        #expect(fixture.primary.review == nil)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
    }

    // MARK: - A window already on the scratch row

    @Test func aWindowOnTheScratchRowWithNoReview_takesTheTabAtOnce() throws {
        let fixture = Fixture()
        let heir = try Self.onTheScratchRow(fixture, showing: fixture.b)

        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c)

        #expect(heir.review?.opening == tab.opening)
        #expect(heir.review?.isShown == false)
        #expect(heir.reviewHasUnsavedComment)
        #expect(heir.parkedReviewArrival == .at(ReviewArrival(heir.selection)))
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.primary.review == nil)
    }

    @Test(arguments: [false, true])
    func aReviewTheWindowLeftOnTheScratchRow_isNeverSwapped_andTheTabWaits(isShown: Bool) throws {
        let fixture = Fixture()
        let heir = try Self.onTheScratchRow(fixture, showing: fixture.b)
        let own = try Self.scratchReview(in: heir, fixture: fixture, isShown: isShown)

        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c)

        #expect(heir.review?.opening == own.opening)
        #expect(heir.review?.isShown == isShown)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
    }

    /// Two windows on the scratch row as a window on `d` closes with a
    /// scratch comment, `tab`.
    private struct TwoOnTheScratchRow {
        let fixture: Fixture
        /// The one that draws the scratch tabs.
        let drawer: ProjectWindowState
        let other: ProjectWindowState
        let tab: ReviewTabState
    }

    /// The window drawing the scratch tabs, holding a review when
    /// `drawerHasReview`, and another on the scratch row, hidden when
    /// `otherIsHidden`, as a window on `d` closes with a scratch comment.
    private static func twoWindowsOnTheScratchRow(drawerHasReview: Bool, otherIsHidden: Bool) throws -> TwoOnTheScratchRow {
        let fixture = Fixture()
        let d = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("d"), suggestedName: "d")
        let other = try Self.onTheScratchRow(fixture, showing: fixture.b)
        let drawer = try Self.onTheScratchRow(fixture, showing: fixture.c)
        fixture.session.claimScratch(for: drawer.id)
        #expect(fixture.session.scratchDrawingWindowID == drawer.id)
        if drawerHasReview {
            _ = try Self.scratchReview(in: drawer, fixture: fixture, isShown: false)
        }
        if otherIsHidden {
            fixture.registry.hide(other.id)
        }
        let tab = try fixture.closeWritingAScratchComment(showing: d)
        return TwoOnTheScratchRow(fixture: fixture, drawer: drawer, other: other, tab: tab)
    }

    @Test func theWindowDrawingTheScratchTabs_isAskedFirst() throws {
        let scene = try Self.twoWindowsOnTheScratchRow(drawerHasReview: false, otherIsHidden: false)

        #expect(scene.drawer.review?.opening == scene.tab.opening)
        #expect(scene.other.review == nil)
    }

    @Test func anotherWindowOnTheScratchRow_takesItWhenTheDrawerCannot() throws {
        let scene = try Self.twoWindowsOnTheScratchRow(drawerHasReview: true, otherIsHidden: false)

        #expect(scene.drawer.review?.opening != scene.tab.opening)
        #expect(scene.other.review?.opening == scene.tab.opening)
        #expect(scene.fixture.registry.parkedScratchReview == nil)
    }

    @Test func aHiddenWindow_neverTakesIt() throws {
        let scene = try Self.twoWindowsOnTheScratchRow(drawerHasReview: true, otherIsHidden: true)

        #expect(scene.other.review == nil)
        #expect(scene.fixture.registry.parkedScratchReview?.tab?.review.opening == scene.tab.opening)
    }

    // MARK: - A window arriving at the scratch row

    @Test func theFrontReviewOfAWindowOnItsProjectsRow_stays_andTheTabComesAtTheScratchRow() throws {
        let fixture = Fixture()
        let agentPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let own = try ProjectWindowsFixture.review(agentPaneID: agentPane)
        fixture.primary.review = own

        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c)

        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.primary.review?.isShown == true)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)

        // To the scratch row: `a`'s review closes as on any move, with
        // nothing written in it, and the tab waiting there comes behind.
        fixture.arriveAtTheScratchRow(fixture.primary)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    @Test(arguments: [true, false])
    func aWindowArrivingWithACommentOfItsOwn_keepsIt_andTheTabWaits(isOfNoProject: Bool) throws {
        let fixture = Fixture()
        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c)
        // A scratch pane's review, or `a`'s, with a comment, in front.
        let agentTab = isOfNoProject ? fixture.scratchTab() : fixture.aTab
        let pane = try #require(agentTab.splitTree.allLeafIDs().first)
        let own = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: isOfNoProject)

        fixture.arriveAtTheScratchRow(fixture.primary)

        // Behind, for its comment, as on any move.
        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
    }

    @Test func aWindowWritingACommentOfItsOwn_onTheScratchRow_takesTheTabAtItsNextScratchReview() throws {
        let fixture = Fixture()
        let heir = try Self.onTheScratchRow(fixture, showing: fixture.b)
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let own = try ProjectWindowsFixture.windowWritingAComment(heir, agentPaneID: pane, isOfNoProject: true)

        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c)

        #expect(heir.review?.opening == own.opening)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
        // Its turns stay out of the sweep while it waits.
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).count == 2)

        // The window's own comment is saved; ⌥⌘R on the scratch tab.
        heir.letGoOfComment()
        fixture.registry.takeParkedReviewBeforeOpening(into: heir, in: fixture.session)

        #expect(heir.review?.opening == tab.opening)
        #expect(heir.review?.isShown == false)
        #expect(heir.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    // MARK: - A window that closes showing no project

    @Test func afterAWindowClosesOnNoProject_arrivingAtTheScratchRow_bringsTheReviewBackBehind() throws {
        let fixture = Fixture()
        // The window closing draws the scratch tabs: it is not handed its
        // own review back.
        let tab = try fixture.closeAWindowOfNoProject(hasComment: true)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
        #expect(fixture.primary.review == nil)

        fixture.arriveAtTheScratchRow(fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        // The person's next move follows the usual rule: the comment keeps
        // it, behind.
        fixture.session.setActiveContainer(.project(fixture.a.id), in: fixture.primary.id)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .putBehind)
    }

    @Test func windowsClosingOnNoProject_keepEveryComment_forTheScratchRow() throws {
        let fixture = Fixture()
        let first = try fixture.closeAWindowOfNoProject(hasComment: true)
        let second = try fixture.closeAWindowOfNoProject(hasComment: true)

        // Both, the one left last first.
        #expect(fixture.registry.parkedScratchReview?.tabs.map(\.review.opening) == [second.opening, first.opening])
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).count == 2)

        fixture.arriveAtTheScratchRow(fixture.primary)
        #expect(fixture.primary.review?.opening == second.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.registry.parkedScratchReview?.tabs.map(\.review.opening) == [first.opening])
    }

    @Test func aWindowClosingOnNoProject_withNoComment_keepsNothing() throws {
        let fixture = Fixture()
        _ = try fixture.closeAWindowOfNoProject(hasComment: false)

        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).isEmpty)
    }

    // MARK: - A review whose agent is on a project's row

    @Test func aReviewWhoseAgentIsOnAProjectsRow_waitsForThatProject_andComesToAWindowArrivingThere() throws {
        let fixture = Fixture()
        let agentPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)

        let tab = try fixture.closeAWindowOfNoProject(agentPaneID: agentPane, hasComment: true)

        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)

        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews[fixture.c.id] == nil)
    }

    @Test func aWindowStandingOnTheAgentsRowWithNoReview_takesItAtOnce() throws {
        let fixture = Fixture()
        let onC = try fixture.window(showing: fixture.c)
        fixture.session.setActiveTab(fixture.cTab.id, in: onC.id, intent: .person)
        let agentPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)

        let tab = try fixture.closeAWindowOfNoProject(agentPaneID: agentPane, hasComment: true)

        #expect(onC.review?.opening == tab.opening)
        #expect(onC.review?.isShown == false)
        #expect(onC.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews[fixture.c.id] == nil)
    }

    /// Where a window on `c` stands, as a review of `cTab`'s agent is left.
    enum StandingOnC: CaseIterable, Sendable {
        /// Another row of `c`, whose strip has no place for the tab.
        case anotherRow
        /// The agent's row, with a review of its own.
        case theAgentsRowWithAReview
    }

    @Test(arguments: StandingOnC.allCases)
    func aWindowThatCannotShowTheTab_isNotHandedIt(_ standing: StandingOnC) throws {
        let fixture = Fixture()
        let onC = try fixture.window(showing: fixture.c)
        switch standing {
        case .anotherRow:
            let worktree = try #require(fixture.session.attachGitWorktree(
                projectID: fixture.c.id,
                label: "w",
                workingDirectory: WorkspaceSessionFixture.projectRootURL("c-w"),
                branchName: "w"
            ))
            let row = ContainerID.worktree(projectID: fixture.c.id, worktreeID: worktree.id)
            fixture.session.openTab(container: row, in: onC.id, intent: .person, selects: true)
            #expect(onC.selection.activeContainerID == row)
        case .theAgentsRowWithAReview:
            fixture.session.setActiveTab(fixture.cTab.id, in: onC.id, intent: .person)
            onC.review = try ProjectWindowsFixture.review()
        }
        let agentPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let own = onC.review

        let tab = try fixture.closeAWindowOfNoProject(agentPaneID: agentPane, hasComment: true)

        #expect(onC.review?.opening == own?.opening)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
    }

    @Test func aWindowOpeningAReview_isNotHandedATab() throws {
        let fixture = Fixture()
        let heir = try Self.onTheScratchRow(fixture, showing: fixture.b)
        // ⌥⌘R, still finding the repository.
        heir.reviewOpenRequest = ReviewOpenRequest(containerID: .loose, tabID: heir.selection.activeTabID)

        let tab = try fixture.closeWritingAScratchComment(showing: fixture.c)

        #expect(heir.review == nil)
        #expect(fixture.registry.parkedScratchReview?.tab?.review.opening == tab.opening)
    }

    @Test func twoReviewsKeptForOneProject_comeBackOneAtEachArrival_bothSafeFromTheSweep() throws {
        let fixture = Fixture()
        let agentPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let first = try fixture.closeAWindowOfNoProject(agentPaneID: agentPane, hasComment: true)
        let second = try fixture.closeAWindowOfNoProject(agentPaneID: agentPane, hasComment: true)

        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tabs.map(\.review.opening) == [second.opening, first.opening])
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).count == 2)

        // The one left last comes first.
        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.primary.review?.opening == second.opening)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tabs.map(\.review.opening) == [first.opening])
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).count == 2)

        // That one is done with; the next arrival at `c` brings the other.
        fixture.primary.letGoOfReview()
        fixture.registry.show(project: fixture.b.id, in: fixture.session, from: fixture.primary, intent: .person)
        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.primary.review?.opening == first.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews[fixture.c.id] == nil)
    }

    @Test func aScratchTabMovedToAProject_thenItsWindowCloses_leavesTheReviewForThatProject() throws {
        let fixture = Fixture()
        let closing = try fixture.window(showing: fixture.c)
        let scratch = fixture.session.openTab(container: .loose, in: closing.id, intent: .person, selects: false)
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.windowWritingAComment(closing, agentPaneID: pane, isOfNoProject: true)
        // The scratch tab is dragged to `c`'s row: its strip shows the tab now.
        fixture.session.moveTab(scratch.id, to: .project(fixture.c.id))
        #expect(fixture.session.tab(containing: pane)?.container == .project(fixture.c.id))

        fixture.registry.close(closing.id, in: fixture.session)

        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.parkedReviews[fixture.c.id]?.tab?.review.opening == tab.opening)
        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
    }
}
