// QuitGateTests.swift
// Weir — ⌘Q asks about every agent, those of hidden windows and of projects no window shows included.

import Foundation
import Testing
@testable import Weir

@MainActor
struct QuitGateTests {
    @Test func anAgentInAHiddenWindowsTab_stillAsksBeforeQuitting() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let registry = WindowRegistry(primary: session.primarySelection)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        try registry.addWindow(#require(session.selection(other)))
        let tab = session.openTab(container: .project(project.id), in: other)
        session.setActiveContainer(.loose)
        registry.hide(other)
        #expect(registry.window(other)?.isHidden == true)
        let pane = tab.splitTree.allLeafIDs()[0]
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())] }

        #expect(session.hasLiveAgentAnywhere())
    }

    @Test func agentsOfAProjectNoWindowShows_count() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        try registry.addWindow(#require(session.selection(other)))
        let tab = session.openTab(container: .project(project.id), in: other)
        session.setActiveContainer(.loose)
        registry.show(registry.primary.id)
        registry.show(other)
        let pane = tab.splitTree.allLeafIDs()[0]
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())] }

        // The window that showed the project closes for good.
        registry.close(other, in: session)

        #expect(registry.window(other) == nil)
        #expect(session.windowIDs.allSatisfy { session.selection($0)?.shownProjectID != project.id })
        #expect(session.hasLiveAgentAnywhere())
    }
}
