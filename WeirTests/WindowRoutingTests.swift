// WindowRoutingTests.swift
// Weir — what each window's selection follows: the actions run in it, and the changes every window shares.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A second window beside the primary moves on its own: an action
/// run in it writes its selection and its history, never the primary's,
/// and a tab or container that goes away moves every window that showed
/// it. The palette's rows are `PaletteExecuteRoutingTests`'.
@MainActor
struct WindowRoutingTests {

    // MARK: - Actions in a window

    @Test func openTab_inASecondWindow_showsItThereOnly() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let other = WorkspaceSessionFixture.addWindow(to: session)

        let opened = session.openTab(container: .loose, in: other)

        #expect(session.selection(other)?.activeTabID == opened.id)
        #expect(session.primarySelection.activeTabID == tab.id)
    }

    @Test func navigationHistory_isEachWindowsOwn() throws {
        let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tabB.id, in: other)
        let before = try #require(session.currentNavTarget(in: other))
        session.setActiveTab(tabA.id, in: other)
        session.recordNavigation(from: before, in: other)

        #expect(session.canNavigateBack(in: other))
        #expect(!session.canNavigateBack(in: session.primaryWindowID))

        session.navigateBack(in: other)
        #expect(session.selection(other)?.activeTabID == tabB.id)
        #expect(session.canNavigateForward(in: other))
        // The primary stays where it was, with no history of its own.
        #expect(session.primarySelection.activeTabID == tabA.id)
        #expect(!session.canNavigateForward(in: session.primaryWindowID))
    }

    @Test func aShortcutRunInASecondWindow_movesThatWindow() {
        let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tabB.id, in: other)

        dispatch(.nextTab, session: session, window: other)

        #expect(session.selection(other)?.activeTabID == tabA.id)
        #expect(session.primarySelection.activeTabID == tabA.id)
        dispatch(.nextTab, session: session, window: other)
        #expect(session.selection(other)?.activeTabID == tabB.id)
        #expect(session.primarySelection.activeTabID == tabA.id)
    }

    @Test func aWindowsOwnAction_isAskedOfThatWindowAlone() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let commands = RecordingWindowCommands()

        for action in [WeirShortcutAction.closeWindow, .toggleChangesPanel, .toggleSidebar] {
            dispatch(action, session: session, window: other, commands: commands)
        }

        #expect(commands.commands(in: other) == [.closeWindow, .toggleChangesPanel, .toggleSidebar])
        #expect(commands.commands(in: session.primaryWindowID).isEmpty)
    }

    @Test func everyWindowShortcutOfTheDispatch_asksTheWindowForItsCommand() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let table: [(WeirShortcutAction, WindowCommand)] = [
            (.newWorktree, .newWorktree), (.openFolder, .openFolder), (.closeWindow, .closeWindow),
            (.newWindow, .newWindow), (.toggleSidebar, .toggleSidebar),
            (.notificationHistory, .toggleNotificationHistory), (.review, .review),
            (.reviewLatestTurn, .reviewLatestTurn), (.toggleChangesPanel, .toggleChangesPanel),
            (.allProjects, .toggleAllProjects), (.keyboardShortcuts, .toggleKeyboardShortcuts),
            (.showNeedsAttention, .showNeedsAttention), (.showOpenTabs, .showOpenTabs),
            (.focusSidebar, .focusSidebar)
        ]
        for (action, command) in table {
            let commands = RecordingWindowCommands()
            dispatch(action, session: session, window: session.primaryWindowID, commands: commands)
            #expect(commands.commands(in: session.primaryWindowID) == [command], "\(action)")
        }
    }

    /// From the palette the sidebar has no keyboard, so Move Project Up and
    /// Down move the project the window shows, in that window's order.
    @Test func theProjectMoves_fromThePalette_moveTheShownProject() {
        let fixture = ProjectWindowsFixture()
        let window = fixture.session.primaryWindowID
        let order = { fixture.session.primarySelection.sidebarArrangement.ordered(fixture.session.projects.map(\.id)) }
        #expect(order() == [fixture.a.id, fixture.b.id, fixture.c.id])

        dispatch(.moveProjectDown, session: fixture.session, window: window)
        #expect(order() == [fixture.b.id, fixture.a.id, fixture.c.id])
        dispatch(.moveProjectUp, session: fixture.session, window: window)
        dispatch(.moveProjectUp, session: fixture.session, window: window)
        #expect(order() == [fixture.a.id, fixture.b.id, fixture.c.id], "the top stays the top")
    }

    @Test func theAttentionShortcuts_walkTheList_forwardThenBack() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let attention = AttentionState()
        var walked: [Bool] = []
        attention.walkAttention = { walked.append($0) }

        for action in [WeirShortcutAction.nextAttention, .previousAttention] {
            dispatch(action, session: session, window: session.primaryWindowID, attention: attention)
        }

        #expect(walked == [true, false])
    }

    @Test func aNewTabInASecondWindow_startsInThatWindowsFolder() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (mode: .inheritPrevious, path: nil) }
        let shown = session.openTab(container: .loose, workingDirectory: URL(fileURLWithPath: "/tmp/weir-window-b"))
        session.openTab(container: .loose, workingDirectory: URL(fileURLWithPath: "/tmp/weir-primary"))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(shown.id, in: other)

        let opened = session.openTab(container: .loose, in: other)

        #expect(opened.workingDirectory == "/tmp/weir-window-b")
    }

    // MARK: - Changes every window shares

    @Test func closingATabOnlyASecondWindowShows_leavesThePrimaryWhereItWas() {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let closing = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(closing.id, in: other)
        session.setActiveTab(first.id)

        session.closeTab(closing.id)

        #expect(session.primarySelection.activeTabID == first.id)
        #expect(session.selection(other)?.activeTabID == first.id)
    }

    @Test func removingAWorktree_movesTheSecondWindowOnItToTheProject() throws {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let primaryTab = session.primarySelection.activeTabID
        let worktree = try #require(session.attachGitWorktree(
            projectID: project.id,
            label: "feature",
            workingDirectory: project.rootURL.appendingPathComponent("feature"),
            branchName: "feature"
        ))
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        let tab = session.openTab(container: container, in: other)

        session.removeWorktree(projectID: project.id, worktreeID: worktree.id)

        #expect(session.selection(other)?.activeContainerID == .project(project.id))
        #expect(session.selection(other)?.activeTabID != tab.id)
        #expect(session.primarySelection.activeTabID == primaryTab)
    }

    @Test func closingATab_movesEveryWindowThatShowedIt() {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let closing = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(closing.id, in: other)

        session.closeTab(closing.id)

        #expect(session.primarySelection.activeTabID == first.id)
        #expect(session.selection(other)?.activeTabID == first.id)
    }

    @Test func movingATab_leavesTheSecondWindowThatShowedItOnTheSource() {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let primaryTab = session.primarySelection.activeTabID
        let sibling = session.openTab(container: .project(project.id), in: other)
        let tab = session.openTab(container: .project(project.id), in: other)

        session.moveTab(tab.id, to: .loose)

        #expect(session.selection(other)?.activeTabID == sibling.id)
        #expect(session.primarySelection.activeTabID == primaryTab)
    }

    @Test func hidingAWorktree_movesTheSecondWindowOnItToTheProject() throws {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let worktree = try #require(session.attachGitWorktree(
            projectID: project.id,
            label: "feature",
            workingDirectory: project.rootURL.appendingPathComponent("feature"),
            branchName: "feature"
        ))
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        session.setActiveContainer(container, in: other)

        session.hideWorktree(projectID: project.id, worktreeID: worktree.id)

        #expect(session.selection(other)?.activeContainerID == .project(project.id))
        #expect(session.primarySelection.shownProjectID != project.id)
    }

    @Test func anUnknownWindow_movesNoWindow() {
        let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()

        session.setActiveTab(tabB.id, in: WindowID())

        #expect(session.primarySelection.activeTabID == tabA.id)
    }

    // MARK: - Helpers

    // A tuple keeps the call sites' destructuring, as the fixtures' do.
    // swiftlint:disable large_tuple
    /// A primary on one project's tab, and a second window on `project`,
    /// which no other window shows: a change to `project` reaches
    /// the second window, and the primary is the one to stay as it was.
    private static func secondWindowShowingAProject() -> (session: WorkspaceSession, project: Project, other: WindowID) {
        let (session, home) = WorkspaceSessionFixture.withProject(name: "home")
        session.openTab(container: .project(home.id))
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("second"), suggestedName: "second")
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(.project(project.id), in: other)
        return (session, project, other)
    }

    // swiftlint:enable large_tuple

    private func dispatch(
        _ action: WeirShortcutAction,
        session: WorkspaceSession,
        window: WindowID,
        commands: RecordingWindowCommands = RecordingWindowCommands(),
        attention: AttentionState = AttentionState()
    ) {
        TabActions.dispatchShortcutAction(
            action,
            session: session,
            attention: attention,
            registry: RecordingSurfaceRegistry(),
            commands: commands,
            trackers: TabActions.SessionTrackers(projection: nil),
            toastCenter: ToastCenter(),
            minPaneSize: 0,
            window: window
        )
    }

    @Test func thePaneOfASecondWindowsTab_namesThatWindow() throws {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let primaryTab = try #require(session.primarySelection.activeTabID.flatMap { session.tab($0) })
        let primaryPane = try #require(primaryTab.splitTree.allLeafIDs().first)
        let shown = session.openTab(container: .project(project.id), in: other)
        let behind = session.openTab(container: .project(project.id), in: other, intent: .person, selects: false)
        let shownPane = try #require(shown.splitTree.allLeafIDs().first)
        let behindPane = try #require(behind.splitTree.allLeafIDs().first)

        #expect(session.window(showingPane: primaryPane) == session.primaryWindowID)
        #expect(session.window(showingPane: shownPane) == other)
        // A tab no window shows, and a pane no tab holds, name no window.
        #expect(session.window(showingPane: behindPane) == nil)
        #expect(session.window(showingPane: UUID()) == nil)
    }

    @Test func theSessionsInFront_areEveryWindows() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let second = session.addOrActivateProject(rootURL: project.rootURL.appendingPathExtension("second"))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(.project(project.id))
        session.setActiveContainer(.project(second.id), in: other)

        #expect(session.shownContainerIDs == [.project(project.id), .project(second.id)])
    }
}

/// A request addressed to one window.
@MainActor
extension WindowRoutingTests {
    @Test func renaming_asksOnlyTheWindowItWasAskedIn() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tab.id, in: other)
        let commands = RecordingWindowCommands()

        TabActions.renameActiveTab(session, in: other, commands: commands)

        #expect(commands.commands(in: other) == [.renameTab(tab.id)])
        #expect(commands.commands(in: session.primaryWindowID).isEmpty)
    }
}
