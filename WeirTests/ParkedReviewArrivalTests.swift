// ParkedReviewArrivalTests.swift
// Weir — whether a review tab a switch brings back with its project comes back in front, behind, or not at all.

import Foundation
import Testing
@testable import Weir

/// The switch that brings a project's review tab back never closes it. A
/// switch that carries a target (⌘J, a notification, a card's item, the
/// menu bar's rows) puts it behind, even on the place the
/// person left; one with no target (project ▾, ⌘O, the palette's projects,
/// a card with no item, going back or forward) leaves it in front or behind
/// as it was left there.
/// The person's next move follows the usual rule.
@MainActor
struct ParkedReviewArrivalTests {
    typealias Fixture = ProjectWindowsFixture

    /// Row R (`a`'s project row, on `aTab`) has the agent whose review is
    /// open in front; row Q is a worktree of `a` with a tab of its own. The
    /// window then leaves for `b`, and `a` keeps the tab.
    private struct Rows {
        let tab: ReviewTabState
        let rowQ: ContainerID
        let qTab: Tab
    }

    private static func reviewInRowR_thenLeave(_ fixture: Fixture, isShown: Bool = true) throws -> Rows {
        let worktree = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.a.id,
            label: "w",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("a-w"),
            branchName: "w"
        ))
        let rowQ = ContainerID.worktree(projectID: fixture.a.id, worktreeID: worktree.id)
        let qTab = fixture.session.openTab(container: rowQ, in: fixture.primary.id, intent: .person, selects: false)
        fixture.session.setActiveTab(fixture.aTab.id, in: fixture.primary.id, intent: .person)
        let agentPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.review(agentPaneID: agentPane)
        fixture.primary.review = tab
        fixture.primary.review?.isShown = isShown
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.primary.review == nil)
        return Rows(tab: tab, rowQ: rowQ, qTab: qTab)
    }

    /// Makes the Needs Attention list with a stopped agent in `tab` of `a`.
    /// The caller holds the navigator, because the list holds it weakly.
    private static func attentionList(
        stopIn tab: Tab,
        fixture: Fixture
    ) -> (store: AttentionQueueStore, navigator: SessionAttentionNavigator) {
        AttentionQueueFixture.stopped(in: tab, projectID: fixture.a.id, session: fixture.session, registry: fixture.registry)
    }

    /// Waits for the task the switch scheduled to settle the arrival
    /// (`WindowRegistry.windowDidSwitchProject`), with no view looking.
    private static func waitForTheSwitchToSettle(_ window: ProjectWindowState) async {
        await pollUntil {
            if case .pending = window.parkedReviewArrival {
                return false
            }
            return true
        }
    }

    /// Returns once every job already queued on the main actor has run, the
    /// task a switch scheduled to settle its arrival among them: the main
    /// actor runs its jobs in the order they were queued. For a test that
    /// shows that task changes nothing, where no state says it has run.
    private static func afterTheTasksQueuedOnTheMainActor() async {
        await Task { @MainActor in }.value
    }

    // MARK: - A switch that carries a target

    @Test(arguments: [true, false])
    func aJumpToAnotherRow_putsTheTabItBringsBackBehind_andClosesNothing(viewLooksFirst: Bool) async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture)
        let (store, navigator) = Self.attentionList(stopIn: rows.qTab, fixture: fixture)
        let item = try #require(store.queue.items.first)

        // ⌘J, the list, a card's item, a menu bar row: back
        // to `a`, on row Q, through `go(to:)`.
        store.focus(item, from: fixture.primary)
        if viewLooksFirst {
            #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        }
        await Self.waitForTheSwitchToSettle(fixture.primary)

        #expect(fixture.primary.selection.activeContainerID == rows.rowQ)
        #expect(fixture.primary.review?.opening == rows.tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        // The person's next move follows the usual rule.
        fixture.session.setActiveContainer(.project(fixture.a.id), in: fixture.primary.id)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .close)
        withExtendedLifetime(navigator) {}
    }

    @Test func aJumpToThePlaceThePersonLeft_stillPutsTheTabBehind() async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture)
        // The agent of the review itself asks for something.
        let (store, navigator) = Self.attentionList(stopIn: fixture.aTab, fixture: fixture)
        let item = try #require(store.queue.items.first)

        store.jump(forward: true, in: fixture.primary)
        await Self.waitForTheSwitchToSettle(fixture.primary)

        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.primary.review?.opening == rows.tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        withExtendedLifetime((navigator, item)) {}
    }

    /// How the app's entries show what they carry (`AppState.reviewTargetMove`).
    private static func move(_ fixture: Fixture) -> ReviewTargetMove {
        ReviewTargetMove(session: fixture.session, registry: RecordingSurfaceRegistry(), windows: fixture.registry)
    }

    /// The way an entry of the app names row Q's tab.
    enum TargetEntry: CaseIterable, Sendable {
        /// A notification's pane.
        case pane
        /// A notification's tab.
        case tab
        /// A notification's row, or the row of a new session that stopped.
        case container
        /// A runtime gone to (`AppState.go(toRuntime:)`).
        case runtime
    }

    @Test(arguments: TargetEntry.allCases)
    func everyEntryWithATarget_selectsItFirst_thenPutsTheTabItBringsBackBehind(_ entry: TargetEntry) async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture)
        let pane = try #require(rows.qTab.splitTree.allLeafIDs().first)
        // As `AppState.openNotificationTarget` and `go(toRuntime:)` find
        // the window.
        let shown = try #require(fixture.registry.present(
            project: fixture.a.id,
            in: fixture.session,
            from: fixture.registry.backgroundCommandTarget
        ))

        switch entry {
        case .pane:
            Self.move(fixture).toPane(pane, in: shown)
        case .tab:
            Self.move(fixture).toTab(rows.qTab.id, in: shown)
        case .container:
            Self.move(fixture).toContainer(rows.rowQ, in: shown)
        case .runtime:
            Self.move(fixture).toAgentPane(tabID: rows.qTab.id, paneID: pane, runtimeID: "r", attention: AttentionState(), in: shown)
        }

        // Settled where the target is, so selected first.
        #expect(shown.selection.activeContainerID == rows.rowQ)
        #expect(shown.parkedReviewArrival == .at(ReviewArrival(shown.selection)))
        await Self.waitForTheSwitchToSettle(shown)
        #expect(shown === fixture.primary)
        #expect(shown.review?.opening == rows.tab.opening)
        #expect(shown.review?.isShown == false)
        #expect(ReviewTabActions.rowChange(for: shown) == .keep)
    }

    @Test func aNotificationWithNoSwitch_putsTheReviewBehind_onItsRowOrAnother() throws {
        let fixture = Fixture()
        let agentPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.review(agentPaneID: agentPane)
        fixture.primary.review = tab

        // The review's own agent's pane: the review stays, behind.
        Self.move(fixture).toPane(agentPane, in: fixture.primary)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)

        // Another row's pane: behind, then the usual rule closes it, with
        // nothing written in it.
        ReviewTabActions.show(window: fixture.primary)
        let rowQ = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.a.id,
            label: "w",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("a-w"),
            branchName: "w"
        ))
        let qTab = fixture.session.openTab(
            container: .worktree(projectID: fixture.a.id, worktreeID: rowQ.id),
            in: fixture.primary.id,
            intent: .person,
            selects: false
        )
        let qPane = try #require(qTab.splitTree.allLeafIDs().first)
        Self.move(fixture).toPane(qPane, in: fixture.primary)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.primary.parkedReviewArrival == nil)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .close)
    }

    @Test func goingBackToTheProject_isASwitchWithNoTarget() async throws {
        let fixture = Fixture()
        let agentPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let tab = try ProjectWindowsFixture.review(agentPaneID: agentPane)
        fixture.primary.review = tab
        let left = try #require(fixture.session.currentNavTarget(in: fixture.primary.id))
        fixture.choose(fixture.bTab, in: fixture.primary)
        // As the app records the move (`AppState`'s history observer).
        fixture.session.recordNavigation(from: left, in: fixture.primary.id)

        fixture.session.navigateBack(in: fixture.primary.id, intent: .person)
        await Self.waitForTheSwitchToSettle(fixture.primary)

        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == true)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
    }

    // MARK: - A switch with no target

    @Test(arguments: [true, false])
    func aSwitchWithNoTarget_bringsTheTabBackAsItWasLeft(wasShown: Bool) async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture, isShown: wasShown)

        // Project ▾.
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)
        await Self.waitForTheSwitchToSettle(fixture.primary)

        #expect(fixture.primary.review?.opening == rows.tab.opening)
        #expect(fixture.primary.review?.isShown == wasShown)
        #expect(fixture.primary.parkedReviewArrival == .at(ReviewArrival(fixture.primary.selection)))
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
    }

    @Test func aCardWithNoItem_namingAnotherRow_putsTheTabBehind() async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture)

        // As `AllProjectsActions.open` opens a card with no item.
        let target = try #require(fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person))
        fixture.session.setActiveContainer(rows.rowQ, in: target.id, intent: .person)
        await Self.waitForTheSwitchToSettle(target)

        #expect(target.review?.opening == rows.tab.opening)
        #expect(target.review?.isShown == false)
        #expect(ReviewTabActions.rowChange(for: target) == .keep)
    }

    // MARK: - The task that settles the switch

    @Test func twoSwitchesInARow_settleWhereTheLastLanded() async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture)

        // To `a`, then on to `c`, then back to `a`, before any task runs.
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)
        fixture.registry.show(project: fixture.c.id, in: fixture.session, from: fixture.primary, intent: .person)
        #expect(fixture.primary.review == nil)
        #expect(fixture.primary.parkedReviewArrival == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == rows.tab.opening)
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)
        await Self.waitForTheSwitchToSettle(fixture.primary)

        #expect(fixture.primary.review?.opening == rows.tab.opening)
        #expect(fixture.primary.review?.isShown == true)
        #expect(fixture.primary.parkedReviewArrival == .at(ReviewArrival(fixture.primary.selection)))
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
    }

    @Test func aWindowClosedBeforeTheTaskRuns_keepsTheCommentForItsProject() async throws {
        let fixture = Fixture()
        let rows = try Self.reviewInRowR_thenLeave(fixture)
        let other = try fixture.window(showing: fixture.c)
        // `other` takes `a`'s tab, with a comment written in it there.
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: other, intent: .person)
        #expect(other.review?.opening == rows.tab.opening)
        other.writeComment()

        fixture.registry.close(other.id, in: fixture.session)
        // Whatever the task does now, it does to a window let go of.
        await Self.afterTheTasksQueuedOnTheMainActor()

        #expect(other.review == nil)
        #expect(other.parkedReviewArrival == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == rows.tab.opening)
        // The primary comes back to `a` and takes it, comment and all.
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)
        await Self.waitForTheSwitchToSettle(fixture.primary)
        #expect(fixture.primary.review?.opening == rows.tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
    }

    // MARK: - Moves after the arrival

    @Test func puttingTheTabBehind_settlesTheArrival_whichTheNextMoveForgets() async throws {
        let fixture = Fixture()
        _ = try Self.reviewInRowR_thenLeave(fixture)
        fixture.registry.show(project: fixture.a.id, in: fixture.session, from: fixture.primary, intent: .person)
        let landed = ReviewArrival(fixture.primary.selection)

        // A target shown as the switch ends: behind, where it stands.
        ReviewTabActions.putBehind(
            window: fixture.primary,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: fixture.primary.id, registry: fixture.registry)
        )
        #expect(fixture.primary.parkedReviewArrival == .at(landed))
        #expect(fixture.primary.review?.isShown == false)
        // The task that comes after finds nothing left to settle.
        await Self.afterTheTasksQueuedOnTheMainActor()
        #expect(fixture.primary.parkedReviewArrival == .at(landed))

        fixture.choose(fixture.aOther, in: fixture.primary)
        #expect(!fixture.primary.isParkedReviewArrival())
        #expect(fixture.primary.parkedReviewArrival == nil)
    }
}

/// A closed window's review with a comment, taken by the next window to
/// show its project: an arrival as a switch's is, with the window's own
/// review, if it has one, left as it is.
extension ParkedReviewArrivalTests {
    typealias ClosingFixture = WindowCloseTests.Fixture

    @Test func aParkedComment_holdsItsTab() throws {
        let fixture = try ClosingFixture()
        let (tab, _) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.other.review = tab
        fixture.other.writeComment()
        fixture.close(fixture.other)
        // A window that shows no project takes the project, and moves to it
        // in the same pass.
        let empty = try fixture.addEmptyWindow()
        let before = empty.selection.activeTabID

        let taken = try fixture.chooseSecond(in: empty)

        #expect(taken === empty)
        #expect(empty.selection.activeTabID == fixture.secondTab.id)
        // In front, and not put behind for the move it arrived with.
        #expect(empty.review?.isShown == true)
        #expect(empty.isParkedReviewArrival())
        #expect(!ReviewTabActions.activeTabChangePutsReviewBehind(from: before, window: empty, session: fixture.session))
        // The tab holds its comment, so nothing replaces or closes it.
        #expect(empty.reviewHasUnsavedComment)
        let other = ReviewTabState(
            root: "/other",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(ReviewTabModel.refusesReplacing(empty.review, with: other, hasUnsavedComment: empty.reviewHasUnsavedComment))
        // Saved or thrown away, nothing holds the tab.
        empty.letGoOfComment()
        #expect(!empty.reviewHasUnsavedComment)

        // The person's next move is theirs: the tab goes behind as usual.
        fixture.session.setActiveContainer(.loose, in: empty.id)
        #expect(!empty.isParkedReviewArrival())
        #expect(ReviewTabActions.activeTabChangePutsReviewBehind(
            from: fixture.secondTab.id,
            window: empty,
            session: fixture.session
        ))
    }

    /// A closed window's review tab with a comment, as a window that showed
    /// no project took it.
    @MainActor
    private struct TakenComment {
        let tab: ReviewTabState
        let window: ProjectWindowState
    }

    private static func takenParkedComment(_ fixture: ClosingFixture) throws -> TakenComment {
        let (tab, _) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.other.review = tab
        fixture.other.writeComment()
        fixture.close(fixture.other)
        let empty = try fixture.addEmptyWindow()
        let taken = try fixture.chooseSecond(in: empty)
        #expect(taken === empty)
        return TakenComment(tab: tab, window: empty)
    }

    @Test func theArrivalOfAParkedTab_answersForNoLaterMoveOfThePersons() throws {
        let fixture = try ClosingFixture()
        let window = try Self.takenParkedComment(fixture).window
        let arrivedOn = try #require(window.selection.activeTabID)
        #expect(window.isParkedReviewArrival())

        // ⌘2: the review goes behind, and another tab comes to front.
        ReviewTabActions.putBehind(
            window: window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: fixture.registry)
        )
        let shell = fixture.session.openTab(container: .project(fixture.second.id), in: window.id)
        // The window's views look as the tab changes: the arrival was
        // settled where it went behind, and this is elsewhere.
        #expect(!window.isParkedReviewArrival())
        #expect(window.parkedReviewArrival == nil)
        // The review is brought back, then the person clicks the tab it
        // arrived on: that move is theirs, and puts the review behind.
        ReviewTabActions.show(window: window)
        fixture.session.setActiveTab(arrivedOn, in: window.id)

        #expect(window.selection.activeTabID == arrivedOn)
        #expect(ReviewTabActions.activeTabChangePutsReviewBehind(from: shell.id, window: window, session: fixture.session))
    }

    @Test func theArrivalIsForgotten_evenWhenTheReviewIsNotInFront() throws {
        let fixture = try ClosingFixture()
        let window = try Self.takenParkedComment(fixture).window
        let arrivedOn = try #require(window.selection.activeTabID)
        // The window's views look as the switch ends, which takes where it
        // landed.
        #expect(window.isParkedReviewArrival())
        window.review?.isShown = false
        // A move with the review behind still forgets the arrival.
        let shell = fixture.session.openTab(container: .project(fixture.second.id), in: window.id)
        #expect(!ReviewTabActions.activeTabChangePutsReviewBehind(from: arrivedOn, window: window, session: fixture.session))
        #expect(window.parkedReviewArrival == nil)

        ReviewTabActions.show(window: window)
        fixture.session.setActiveTab(arrivedOn, in: window.id)
        #expect(ReviewTabActions.activeTabChangePutsReviewBehind(from: shell.id, window: window, session: fixture.session))
    }

    /// The second project's two worktrees, and the review tab of a comment
    /// begun on worktree A's agent.
    @MainActor
    private struct TwoRows {
        let rowA: ContainerID
        let rowB: ContainerID
        let tab: ReviewTabState
    }

    /// A comment begun in the review of worktree A's agent, in the window
    /// that shows the second project; the window then moved on to worktree
    /// B (the tab behind) when `movesOn`, and closed.
    private static func commentInWorktreeA(_ fixture: ClosingFixture, movesOn: Bool) throws -> TwoRows {
        let projectID = fixture.second.id
        let worktreeA = try #require(fixture.session.attachGitWorktree(
            projectID: projectID,
            label: "a",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("a"),
            branchName: "a"
        ))
        let worktreeB = try #require(fixture.session.attachGitWorktree(
            projectID: projectID,
            label: "b",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("b"),
            branchName: "b"
        ))
        let rowA = ContainerID.worktree(projectID: projectID, worktreeID: worktreeA.id)
        let rowB = ContainerID.worktree(projectID: projectID, worktreeID: worktreeB.id)
        let agent = fixture.session.openTab(container: rowA, in: fixture.other.id)
        var tab = try ProjectWindowsFixture.reviewAndHunk().tab
        tab.agentPaneID = agent.splitTree.allLeafIDs()[0]
        if movesOn {
            fixture.session.setActiveContainer(rowB, in: fixture.other.id)
            tab.isShown = false
        }
        fixture.other.review = tab
        fixture.other.writeComment()
        fixture.close(fixture.other)
        return TwoRows(rowA: rowA, rowB: rowB, tab: tab)
    }

    @Test(arguments: [true, false])
    func aParkedTabOfAnotherRow_waitsBehind_whateverTheWindowShowed(takenByAWindowWithNoProject: Bool) throws {
        let fixture = try ClosingFixture()
        let rows = try Self.commentInWorktreeA(fixture, movesOn: true)
        #expect(fixture.session.projectViews[fixture.second.id]?.activeContainerID == rows.rowB)
        let from = try takenByAWindowWithNoProject ? fixture.addEmptyWindow() : fixture.primary

        let taken = try fixture.chooseSecond(in: from)

        #expect(taken === from)
        #expect(taken.selection.activeContainerID == rows.rowB)
        // Kept, and behind: worktree B's strip has no place for it.
        #expect(taken.review?.agentPaneID == rows.tab.agentPaneID)
        #expect(taken.review?.isShown == false)
        // Its arrival stands too: the switch that brought it never closes
        // it, nor puts it behind a terminal it is already behind.
        #expect(taken.parkedReviewArrival != nil)
        #expect(ReviewTabActions.rowChange(for: taken) == .keep)
        #expect(taken.reviewHasUnsavedComment)
    }

    @Test(arguments: [true, false])
    func aParkedTabOfTheRowShown_comesToFront_andACallersMoveIsThePersons(takenByAWindowWithNoProject: Bool) throws {
        let fixture = try ClosingFixture()
        let rows = try Self.commentInWorktreeA(fixture, movesOn: false)
        let from = try takenByAWindowWithNoProject ? fixture.addEmptyWindow() : fixture.primary

        let taken = try fixture.chooseSecond(in: from)

        #expect(taken === from)
        #expect(taken.selection.activeContainerID == rows.rowA)
        #expect(taken.review?.isShown == true)
        #expect(taken.isParkedReviewArrival())
        // The all projects sheet moves the window on to its card's session
        // at once: whatever the window showed, a move of the person's.
        fixture.session.setActiveContainer(rows.rowB, in: taken.id)
        #expect(!taken.isParkedReviewArrival())
        #expect(taken.parkedReviewArrival == nil)
    }

    @Test func aParkedReview_isNotTakenByAWindowWithAReviewOfItsOwn() throws {
        let fixture = try ClosingFixture()
        let (tab, _) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.other.review = tab
        fixture.other.writeComment()
        fixture.close(fixture.other)
        // A window with no project, reviewing a scratch pane with a comment
        // being written: the review stays with the window as it switches.
        let empty = try fixture.addEmptyWindow()
        let scratch = fixture.session.openTab(container: .loose, in: empty.id, intent: .person, selects: false)
        let ownReview = ReviewTabState(
            root: "/other",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: scratch.splitTree.allLeafIDs()[0],
            destinationPaneID: nil,
            opening: UUID(),
            isOfNoProject: true
        )
        empty.review = ownReview
        empty.writeComment()

        let taken = try fixture.chooseSecond(in: empty)

        #expect(taken === empty)
        #expect(empty.review == ownReview)
        #expect(fixture.registry.parkedReviews[fixture.second.id]?.tab?.review == tab)
    }
}
