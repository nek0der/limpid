// GhosttyActionRoutingTests.swift
// Limpid — where a libghostty GOTO_TAB goes: the tab beside the key's pane, in the window showing it.

import Foundation
import GhosttyKit
import Testing
@testable import Limpid

/// GOTO_TAB arrives from libghostty, not through the menu, so it carries no
/// window of the menu's. It is resolved from the pane the key went to.
@MainActor
struct GhosttyActionRoutingTests {
    @Test func aKeyInASecondWindowsPane_movesThatWindow() throws {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let second = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(first.id, in: other)
        let pane = try #require(first.splitTree.allLeafIDs().first)

        let route = GotoTabRoute.resolve(
            rawIndex: GHOSTTY_GOTO_TAB_NEXT.rawValue,
            fromPane: pane,
            commandWindow: session.primaryWindowID,
            in: session
        )

        #expect(route == GotoTabRoute.Route(tabID: second.id, window: other))
    }

    @Test func theTabsStepped_areThoseOfThePanesOwnContainer() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let projectTab = session.openTab(container: .project(project.id))
        let projectSecond = session.openTab(container: .project(project.id))
        session.openTab(container: .loose)
        // The primary stays on its scratch tab, showing no project.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)

        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(projectTab.id, in: other)
        let pane = try #require(projectTab.splitTree.allLeafIDs().first)

        let last = GotoTabRoute.resolve(
            rawIndex: GHOSTTY_GOTO_TAB_LAST.rawValue,
            fromPane: pane,
            commandWindow: session.primaryWindowID,
            in: session
        )
        let numbered = GotoTabRoute.resolve(rawIndex: 2, fromPane: pane, commandWindow: session.primaryWindowID, in: session)

        #expect(last == GotoTabRoute.Route(tabID: projectSecond.id, window: other))
        #expect(numbered == GotoTabRoute.Route(tabID: projectSecond.id, window: other))
        #expect(GotoTabRoute.resolve(rawIndex: 3, fromPane: pane, commandWindow: session.primaryWindowID, in: session) == nil)
    }

    @Test func gotoTabWithNoPane_movesTheCommandTargetsWindow() {
        // A project's tabs: scratch tabs draw in one window only.
        let (session, project) = WorkspaceSessionFixture.withProject()
        let first = session.openTab(container: .project(project.id))
        let second = session.openTab(container: .project(project.id))
        session.openTab(container: .project(project.id))
        // The primary moves on to another project; the window that commands
        // act in shows the second tab of this one.
        let elsewhere = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("elsewhere"))
        let elsewhereTab = session.openTab(container: .project(elsewhere.id))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(second.id, in: other)

        let route = GotoTabRoute.resolve(
            rawIndex: GHOSTTY_GOTO_TAB_PREVIOUS.rawValue,
            fromPane: nil,
            commandWindow: other,
            in: session
        )

        #expect(route == GotoTabRoute.Route(tabID: first.id, window: other))
        #expect(session.primarySelection.activeTabID == elsewhereTab.id)
        // A window the session does not know moves nothing.
        #expect(GotoTabRoute.resolve(
            rawIndex: GHOSTTY_GOTO_TAB_PREVIOUS.rawValue,
            fromPane: nil,
            commandWindow: WindowID(),
            in: session
        ) == nil)
    }

    @Test func gotoTabFromAPaneNoWindowDraws_movesNothing() throws {
        let session = WorkspaceSession()
        let hidden = session.openTab(container: .loose)
        session.openTab(container: .loose)
        // The primary shows a third tab; no window shows `hidden`.
        session.openTab(container: .loose)
        let pane = try #require(hidden.splitTree.allLeafIDs().first)

        let route = GotoTabRoute.resolve(
            rawIndex: GHOSTTY_GOTO_TAB_NEXT.rawValue,
            fromPane: pane,
            commandWindow: session.primaryWindowID,
            in: session
        )

        #expect(route == nil)
    }

    @Test func twoWindowsOnOneTab_resolveToThePrimary() throws {
        // A project's tab: scratch tabs draw in one window only.
        let (session, project) = WorkspaceSessionFixture.withProject()
        let first = session.openTab(container: .project(project.id))
        session.openTab(container: .project(project.id))
        session.setActiveTab(first.id)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(first.id, in: other)
        let pane = try #require(first.splitTree.allLeafIDs().first)

        let route = GotoTabRoute.resolve(
            rawIndex: GHOSTTY_GOTO_TAB_NEXT.rawValue,
            fromPane: pane,
            commandWindow: other,
            in: session
        )

        #expect(route?.window == session.primaryWindowID)
    }
}
