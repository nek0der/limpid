// ScratchOwnerTests.swift
// Weir — the window that draws the scratch tabs: the last to choose them, handing them on as it moves away or hides.

import Foundation
import Testing
@testable import Weir

/// The scratch tabs, which belong to no project, draw in one window at a
/// time: the last to choose them. The other window is mostly a new
/// one, which shows nothing until the person chooses the scratch tabs or a
/// project in it (`WorkspaceSession.addWindow(showing:layoutFrom:)`).
@MainActor
struct ScratchOwnerTests {
    @Test func choosingScratchInAnotherWindow_movesItThere() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID).windowID
        session.claimScratch(for: nil)

        session.setActiveContainer(.loose, in: other)

        #expect(session.showsScratch(in: other))
        #expect(!session.showsScratch(in: nil))
        // "Show Here" in the first window takes them back.
        session.claimScratch(for: nil)
        #expect(session.showsScratch(in: nil))
        #expect(!session.showsScratch(in: other))
    }

    @Test func aProjectTab_leavesTheScratchWhereItIs() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        session.setActiveContainer(.loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)

        session.openTab(container: .project(project.id), in: other)

        #expect(session.showsScratch(in: nil))
        #expect(session.scratchOwnerWindowID == session.primaryWindowID)
    }

    @Test func closingAScratchTabTwoWindowsHaveSelected_leavesItWithTheWindowThatChoseIt() {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let closing = session.openTab(container: .loose)
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID).windowID
        session.setActiveTab(closing.id, in: other)
        // The primary chose it last; the other window only has it selected.
        session.setActiveTab(closing.id)

        session.closeTab(closing.id)

        #expect(session.primarySelection.activeTabID == first.id)
        #expect(session.selection(other)?.activeTabID == first.id)
        #expect(session.scratchDrawingWindowID == session.primaryWindowID)
    }

    @Test func theOwnerMovingOn_leavesTheScratchToAWindowThatHasItSelected() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let scratch = session.openTab(container: .loose)
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID).windowID
        session.setActiveTab(scratch.id, in: other)
        session.setActiveTab(scratch.id)
        #expect(!session.showsScratch(in: other))
        #expect(session.undrawnWindowIDs == [other])

        session.openTab(container: .project(project.id))

        // The primary left the scratch tabs: the other window draws them,
        // and says nothing about another window.
        #expect(session.showsScratch(in: other))
        #expect(session.scratchDrawingWindowID == other)
        #expect(session.undrawnWindowIDs.isEmpty)
    }

    @Test func aScratchTabAWindowDoesNotDraw_isNotShownThere() {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID).windowID
        session.setActiveTab(tab.id, in: other)
        session.claimScratch(for: other)

        #expect(session.windows(showing: tab.id) == [other])
        #expect(session.window(showingPane: paneID) == other)
        #expect(session.shownTabIDs == [tab.id])
    }

    @Test func aWindowWhoseProjectWentAway_takesOnlyAProjectNoOtherWindowShows() {
        let (session, first) = WorkspaceSessionFixture.withProject(name: "first")
        let second = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("follow")
        )
        session.setActiveContainer(.project(first.id))
        session.primarySelection.projectID = first.id
        let switches = ProjectSwitchRecorder.connect(to: session)
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID).windowID
        session.setActiveContainer(.project(second.id), in: other)

        session.removeProject(second.id)

        // The only project left is the primary's: the window shows none
        // rather than a second one for it, and goes to the scratch tabs.
        #expect(session.selection(other)?.shownProjectID == nil)
        #expect(session.selection(other)?.activeContainerID == .loose)
        #expect(session.primarySelection.shownProjectID == first.id)
        #expect(switches.raised.isEmpty)
    }

    @Test func movingAScratchTabAway_movesAWindowThatHadItSelectedWithoutDrawingIt() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let sibling = session.openTab(container: .loose)
        let moving = session.openTab(container: .loose)
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID).windowID
        session.setActiveTab(moving.id, in: other)
        // The primary chose it last and draws it; the other only has it selected.
        session.setActiveTab(moving.id)
        #expect(!session.showsScratch(in: other))

        session.moveTab(moving.id, to: .project(project.id))

        #expect(session.primarySelection.activeTabID == sibling.id)
        #expect(session.selection(other)?.activeTabID == sibling.id)
    }

    // MARK: - A hidden window

    @Test func aHiddenWindow_drawsNothing() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let projectTab = session.openTab(container: .project(project.id))
        let scratch = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(scratch.id, in: other)
        session.setActiveTab(projectTab.id)
        let scratchPane = try #require(scratch.splitTree.allLeafIDs().first)
        #expect(session.shownTabIDs == [projectTab.id, scratch.id])

        session.setWindow(other, isHidden: true)

        // A hidden window draws nothing, not even the scratch tab another
        // window could.
        #expect(session.shownTabIDs == [projectTab.id])
        #expect(session.shownContainerIDs == [.project(project.id)])
        #expect(session.window(showingPane: scratchPane) == nil)
        #expect(session.scratchDrawingWindowID == nil)
        session.setActiveTab(scratch.id)
        #expect(session.scratchDrawingWindowID == session.primaryWindowID)

        session.setWindow(other, isHidden: false)
        #expect(session.shownContainerIDs == [.loose])
    }

    @Test func hidingTheWindowDrawingTheScratch_handsItToAnotherWithItSelected_andBack() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tab.id, in: other)
        #expect(session.scratchDrawingWindowID == other)
        #expect(session.undrawnWindowIDs == [session.primaryWindowID])

        session.setWindow(other, isHidden: true)

        #expect(session.scratchDrawingWindowID == session.primaryWindowID)
        #expect(session.undrawnWindowIDs == [other])

        session.setWindow(other, isHidden: false)

        #expect(session.scratchDrawingWindowID == other)
        #expect(session.undrawnWindowIDs == [session.primaryWindowID])
    }
}
