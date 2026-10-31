// NavActionsTests.swift
// Weir — ⌘1…⌘9 jump to the Nth tab and ⇧⌘] / ⇧⌘[ move to the next or previous one, among the tabs of the container a window shows.

import Foundation
import Testing
@testable import Weir

@MainActor
struct NavActionsTests {

    // MARK: - activateTabInActiveContainer

    @Test func theNthTab_ofTheActiveContainer_becomesActive() {
        let session = WorkspaceSession()
        let first = session.openTabInActiveScope()
        let second = session.openTabInActiveScope()
        let third = session.openTabInActiveScope()

        NavActions.activateTabInActiveContainer(at: 0, in: session)
        #expect(session.primarySelection.activeTabID == first.id)
        NavActions.activateTabInActiveContainer(at: 1, in: session)
        #expect(session.primarySelection.activeTabID == second.id)
        NavActions.activateTabInActiveContainer(at: 2, in: session)
        #expect(session.primarySelection.activeTabID == third.id)
    }

    @Test func anIndexPastTheTabs_changesNothing() {
        let session = WorkspaceSession()
        let only = session.openTabInActiveScope()

        NavActions.activateTabInActiveContainer(at: 5, in: session)
        #expect(session.primarySelection.activeTabID == only.id)
        NavActions.activateTabInActiveContainer(at: -1, in: session)
        #expect(session.primarySelection.activeTabID == only.id)
    }

    // MARK: - cycleTab

    @Test func theNextTab_isTheOneAfter_wrappingPastTheLast() {
        let session = WorkspaceSession()
        let t1 = session.openTabInActiveScope()
        let t2 = session.openTabInActiveScope()
        let t3 = session.openTabInActiveScope()
        session.setActiveTab(t1.id)

        NavActions.cycleTab(session, forward: true)
        #expect(session.primarySelection.activeTabID == t2.id)
        NavActions.cycleTab(session, forward: true)
        #expect(session.primarySelection.activeTabID == t3.id)
        NavActions.cycleTab(session, forward: true)
        #expect(session.primarySelection.activeTabID == t1.id, "cycle wraps after the last tab")
    }

    @Test func thePreviousTab_isTheOneBefore_wrappingPastTheFirst() {
        let session = WorkspaceSession()
        let t1 = session.openTabInActiveScope()
        let t2 = session.openTabInActiveScope()
        let t3 = session.openTabInActiveScope()
        session.setActiveTab(t1.id)

        NavActions.cycleTab(session, forward: false)
        #expect(session.primarySelection.activeTabID == t3.id, "cycle wraps to the last tab on backward from first")
        NavActions.cycleTab(session, forward: false)
        #expect(session.primarySelection.activeTabID == t2.id)
    }

    // MARK: - A container with no tabs

    /// The keys a person can press with no tab in front of them.
    enum TabKey: String, CaseIterable {
        case first
        case next
        case previous

        @MainActor
        func press(in session: WorkspaceSession) {
            switch self {
            case .first: NavActions.activateTabInActiveContainer(at: 0, in: session)
            case .next: NavActions.cycleTab(session, forward: true)
            case .previous: NavActions.cycleTab(session, forward: false)
            }
        }
    }

    /// A project with no tabs shown while a scratch tab exists elsewhere:
    /// the keys reach no tab outside the container.
    @Test(arguments: TabKey.allCases)
    func aContainerWithNoTabs_isLeftWithNoActiveTab(key: TabKey) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "empty")
        _ = session.openTabInActiveScope()
        session.setActiveContainer(.project(project.id))
        #expect(session.primarySelection.activeTabID == nil)

        key.press(in: session)

        #expect(session.primarySelection.activeTabID == nil)
    }

    // MARK: - In a window of its own

    @Test func theNextTab_inASecondWindow_movesOnlyThatWindow() {
        let session = WorkspaceSession()
        let first = session.openTabInActiveScope()
        let second = session.openTabInActiveScope()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(first.id, in: other)

        NavActions.cycleTab(session, forward: true, in: other)

        #expect(session.selection(other)?.activeTabID == second.id)
        #expect(session.primarySelection.activeTabID == second.id)
        NavActions.cycleTab(session, forward: true, in: other)
        #expect(session.selection(other)?.activeTabID == first.id)
        #expect(session.primarySelection.activeTabID == second.id)
    }

    @Test func theNthTab_isOfTheContainerThatWindowShows() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let projectTab = session.openTab(container: .project(project.id))
        let loose = session.openTab(container: .loose)
        // The primary stays on its scratch tab, showing no project.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)

        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(.project(project.id), in: other)

        NavActions.activateTabInActiveContainer(at: 0, in: session, window: other)

        #expect(session.selection(other)?.activeTabID == projectTab.id)
        #expect(session.primarySelection.activeTabID == loose.id)
    }
}
