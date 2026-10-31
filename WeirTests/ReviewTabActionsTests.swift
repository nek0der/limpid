// ReviewTabActionsTests.swift
// Weir — the review tab among a window's tabs: opening it through the window's stores, stepping to it and past it,
// putting it behind a terminal tab, and closing it.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Review tab actions")
struct ReviewTabActionsTests {
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let window: ProjectWindowState
        let first: Tab
        let second: Tab

        init() {
            let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
            let container = ContainerID.project(project.id)
            first = session.openTab(container: container)
            second = session.openTab(container: container)
            self.session = session
            window = ProjectWindowState(selection: session.primarySelection)
        }

        var tabs: [Tab] {
            session.tabs(in: session.primarySelection.activeContainerID)
        }

        /// A review opened from `agent`, in front unless said otherwise.
        func openReview(from agent: UUID?, isShown: Bool = true) {
            window.review = ReviewTabState(
                root: "/repo",
                selection: .uncommitted(includesChangesOutsideTurns: false),
                fixedPoint: ReviewTabFixedPoint(),
                agentPaneID: agent,
                destinationPaneID: agent,
                isShown: isShown,
                opening: UUID()
            )
            window.reviewPresentation.open(URL(fileURLWithPath: "/repo"), originPaneID: agent, initialScope: .uncommitted)
        }

        func cycle(forward: Bool) {
            ReviewTabActions.cycleTab(
                forward: forward,
                window: window,
                session: session,
                registry: RecordingSurfaceRegistry(),
                paneVisibility: PaneVisibilityReporter()
            )
        }
    }

    /// An open that finds no repository, or whose person moved on, leaves
    /// no request behind: while one stands, the window is taken to be
    /// opening a review and is passed over for one another window parks.
    /// A later open's request is that one's to clear.
    @Test func anOpen_clearsItsRequest_howeverItEnds() async {
        let window = ProjectWindowState(id: WindowID())
        let request = ReviewOpenRequest(containerID: .loose, tabID: nil)
        let found: URL? = await window.openingReview(request) {
            #expect(window.reviewOpenRequest == request)
            return nil
        }
        #expect(found == nil)
        #expect(window.reviewOpenRequest == nil)

        let later = ReviewOpenRequest(containerID: .loose, tabID: nil)
        await window.openingReview(request) {
            window.reviewOpenRequest = later
        }
        #expect(window.reviewOpenRequest == later)
    }

    @Test func steppingPastTheLastTerminalTab_reachesTheReview_andPastItTheFirstTab() throws {
        let fixture = Fixture()
        let last = try #require(fixture.tabs.last)
        fixture.session.setActiveTab(last.id)
        fixture.openReview(from: nil, isShown: false)

        fixture.cycle(forward: true)
        #expect(fixture.window.review?.isShown == true)
        #expect(fixture.session.primarySelection.activeTabID == last.id, "the terminal tab stays the one behind it")

        fixture.cycle(forward: true)
        #expect(fixture.window.review?.isShown == false)
        #expect(fixture.session.primarySelection.activeTabID == fixture.tabs.first?.id)
    }

    @Test func steppingBackFromTheFirstTerminalTab_reachesTheReview_andBackFromItTheLastTab() throws {
        let fixture = Fixture()
        let first = try #require(fixture.tabs.first)
        fixture.session.setActiveTab(first.id)
        fixture.openReview(from: nil, isShown: false)

        fixture.cycle(forward: false)
        #expect(fixture.window.review?.isShown == true)

        fixture.cycle(forward: false)
        #expect(fixture.window.review?.isShown == false)
        #expect(fixture.session.primarySelection.activeTabID == fixture.tabs.last?.id)
    }

    @Test func withoutAReview_theTerminalTabsStepAsBefore() throws {
        let fixture = Fixture()
        let tabs = fixture.tabs
        let last = try #require(tabs.last)
        fixture.session.setActiveTab(last.id)

        fixture.cycle(forward: true)

        #expect(fixture.session.primarySelection.activeTabID == tabs.first?.id)
        #expect(fixture.window.review == nil)
    }

    @Test func pickingATerminalTab_putsTheReviewBehindIt() {
        let fixture = Fixture()
        fixture.openReview(from: nil)

        ReviewTabActions.hide(
            window: fixture.window,
            showing: fixture.first.id,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )

        #expect(fixture.window.review?.isShown == false, "still open")
        #expect(fixture.session.primarySelection.activeTabID == fixture.first.id)
        ReviewTabActions.show(window: fixture.window)
        #expect(fixture.window.review?.isShown == true)
    }

    @Test func goingToTheTabBehindTheReview_bringsItInFront_andDropsAnOpenStillOnItsWay() {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        fixture.openReview(from: nil)
        fixture.window.reviewOpenRequest = ReviewOpenRequest(
            containerID: fixture.session.primarySelection.activeContainerID,
            tabID: fixture.session.primarySelection.activeTabID
        )

        // ⌘1 on the tab already behind the review, or ⌘J to one of its panes.
        ReviewTabActions.putBehind(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )

        #expect(fixture.window.review?.isShown == false)
        #expect(fixture.window.reviewOpenRequest == nil, "a late answer would cover where the person went")
    }

    @Test func anOpen_landsOnlyWhereThePersonAskedForIt() {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        let request = ReviewOpenRequest(
            containerID: fixture.session.primarySelection.activeContainerID,
            tabID: fixture.session.primarySelection.activeTabID
        )
        fixture.window.reviewOpenRequest = request

        #expect(ReviewTabActions.isCurrent(request, window: fixture.window, session: fixture.session))
        // ⌘T, a session's row, or a notification while Git answers.
        fixture.session.setActiveTab(fixture.second.id)
        #expect(!ReviewTabActions.isCurrent(request, window: fixture.window, session: fixture.session))
        fixture.session.setActiveTab(fixture.first.id)
        fixture.window.reviewOpenRequest = ReviewOpenRequest(
            containerID: fixture.session.primarySelection.activeContainerID,
            tabID: fixture.session.primarySelection.activeTabID
        )
        #expect(!ReviewTabActions.isCurrent(request, window: fixture.window, session: fixture.session), "a newer open replaced it")
    }

    @Test func closingTheOldSessionsReview_leavesAnOpenAskedForInTheNewOne() {
        let fixture = Fixture()
        fixture.openReview(from: nil)
        // ⌘J to another session's turn asked for its review there.
        let request = ReviewOpenRequest(
            containerID: fixture.session.primarySelection.activeContainerID,
            tabID: fixture.session.primarySelection.activeTabID
        )
        fixture.window.reviewOpenRequest = request

        ReviewTabActions.close(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(),
            returnsToAgent: false
        )

        #expect(fixture.window.reviewOpenRequest == request)
    }

    @Test func aTerminalTabComingInFront_putsTheReviewBehind_butATabClosedUnderItDoesNot() {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        fixture.openReview(from: nil)

        #expect(ReviewTabActions.activeTabChangePutsReviewBehind(from: fixture.first.id, window: fixture.window, session: fixture.session))
        fixture.session.closeTab(fixture.first.id)
        #expect(!ReviewTabActions.activeTabChangePutsReviewBehind(
            from: fixture.first.id,
            window: fixture.window,
            session: fixture.session
        ), "the person did not move")
        fixture.window.review?.isShown = false
        #expect(!ReviewTabActions.activeTabChangePutsReviewBehind(
            from: fixture.second.id,
            window: fixture.window,
            session: fixture.session
        ))
    }

    @Test func closing_goesBackToTheAgentsTab_andLetsGoOfTheReview() throws {
        let fixture = Fixture()
        let agent = try #require(fixture.first.splitTree.allLeafIDs().first)
        fixture.session.setActiveTab(fixture.second.id)
        fixture.openReview(from: agent)

        ReviewTabActions.close(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )

        #expect(fixture.window.review == nil)
        #expect(fixture.window.reviewSession == nil)
        #expect(!fixture.window.reviewPresentation.isPresented)
        #expect(fixture.session.primarySelection.activeTabID == fixture.first.id)
    }

    @Test func closingAfterThePersonWentElsewhere_leavesThemThere() throws {
        let fixture = Fixture()
        let agent = try #require(fixture.first.splitTree.allLeafIDs().first)
        fixture.session.setActiveTab(fixture.second.id)
        fixture.openReview(from: agent)

        ReviewTabActions.close(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(),
            returnsToAgent: false
        )

        #expect(fixture.window.review == nil)
        #expect(fixture.session.primarySelection.activeTabID == fixture.second.id)
    }

    @Test func hidingTheWindow_closesItsReview_unlessACommentIsBeingWritten() {
        let fixture = Fixture()
        fixture.openReview(from: nil)
        fixture.window.reviewOpenRequest = ReviewOpenRequest(containerID: fixture.session.primarySelection.activeContainerID, tabID: nil)
        fixture.window.writeComment()

        ReviewTabActions.windowHidden(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )
        #expect(fixture.window.review != nil, "kept for when the window comes back")
        #expect(fixture.window.reviewOpenRequest == nil, "an open on its way would open it again")

        fixture.window.letGoOfComment()
        ReviewTabActions.windowHidden(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )
        #expect(fixture.window.review == nil)
        #expect(!fixture.window.reviewPresentation.isPresented)
    }

    @Test func theReviewTab_isInItsOwnSessionsStripOnly() throws {
        let fixture = Fixture()
        let agent = try #require(fixture.first.splitTree.allLeafIDs().first)
        let container = try #require(fixture.session.tab(containing: agent)?.container)
        fixture.openReview(from: agent)
        let elsewhere = ContainerID.project(UUID())

        #expect(fixture.window.reviewStripTab(in: container, session: fixture.session) == .inFront)
        #expect(fixture.window.reviewStripTab(in: elsewhere, session: fixture.session) == .none)
        fixture.openReview(from: nil)
        #expect(fixture.window.reviewStripTab(in: elsewhere, session: fixture.session) == .inFront, "no agent's pane to place it by")
    }

    @Test func theWindowsReview_opensAsATabInFront() {
        let fixture = Fixture()
        fixture.openReview(from: nil)

        #expect(fixture.window.reviewPresentation.isPresented)
        #expect(fixture.window.reviewStripTab(in: fixture.session.primarySelection.activeContainerID, session: fixture.session) == .inFront)
    }

    // MARK: - Opening through the window's stores

    private static func paneVisibility(_ fixture: ActionStoresFixture) -> PaneVisibilityReporter {
        PaneVisibilityReporter(windowID: fixture.window.id, registry: fixture.windows)
    }

    @Test func showCurrentDiff_opensTheTabOnTheWorktreesTopLevel() async {
        let fixture = ActionStoresFixture()

        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)

        let tab = fixture.window.review
        #expect(tab?.root == fixture.root)
        #expect(tab?.isShown == true)
        #expect(fixture.window.reviewSession != nil)
        #expect(fixture.toasts.current(in: fixture.window.id) == nil)
    }

    @Test func outsideARepository_noTabOpens_andAToastSaysWhy() async {
        let fixture = ActionStoresFixture()
        fixture.gitRoot = { _ in throw ReviewError.gitFailed }

        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)

        #expect(fixture.window.review == nil)
        #expect(fixture.toasts.current(in: fixture.window.id) != nil)
    }

    @Test func reviewUnviewedWithNothingUnviewed_opensTheTabSayingSo() async {
        let fixture = ActionStoresFixture()

        await ReviewTabActions.open(.worktreeUnviewedTurns, agentPaneID: nil, window: fixture.window, stores: fixture.review)

        #expect(fixture.window.review?.selection == .worktreeUnviewedTurns(.none))
        #expect(fixture.toasts.current(in: fixture.window.id) == nil)
    }

    @Test func theShortcut_closesTheTabInFront() async {
        let fixture = ActionStoresFixture()
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        #expect(fixture.window.review?.isShown == true)

        await ReviewTabActions.toggle(window: fixture.window, stores: fixture.review, paneVisibility: Self.paneVisibility(fixture))

        #expect(fixture.window.review == nil)
    }

    @Test func aTabPutBehind_comesBackToFrontWithItsScope() async {
        let fixture = ActionStoresFixture()
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        let opening = fixture.window.review?.opening

        ReviewTabActions.putBehind(
            window: fixture.window,
            session: fixture.session,
            registry: fixture.registry,
            paneVisibility: Self.paneVisibility(fixture)
        )
        #expect(fixture.window.review?.isShown == false)
        ReviewTabActions.show(window: fixture.window)

        #expect(fixture.window.review?.isShown == true)
        #expect(fixture.window.review?.opening == opening)
    }
}
