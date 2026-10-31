// SessionLaunchDestinationTests.swift
// Weir — where a new session's tab lands once its setup ends: in front or behind, and in which window.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Where a setup that ends lands: decided once, in the
/// launch's window while it shows the session's project, and in no shown
/// window otherwise.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLaunchDestinationTests {
    typealias Fixture = SessionLaunchFixture

    private func begin(_ fixture: Fixture, in window: WindowID? = nil) {
        fixture.begin(Fixture.shell, in: window)
    }

    private static func row(_ fixture: Fixture) -> ContainerID {
        .worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
    }

    @Test func aSetupThatStaysBehind_opensItsTabWithoutSelectingIt() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let elsewhere = fixture.session.openTab(container: .project(fixture.project.id))
            let selection = fixture.session.primarySelection
            let changed = Recorded(false)
            withObservationTracking {
                _ = selection.activeTabID
                _ = selection.activeContainerID
            } onChange: {
                changed.value = true
            }

            begin(fixture)

            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.primarySelection.activeTabID == elsewhere.id)
            // Not opened in front and put back: never written at all.
            #expect(!changed.value)
        }
    }

    @Test func aSetupBehindAShellOfItsRow_leavesTheRowsLastTabOnTheShell() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let shell = fixture.session.openTab(container: Self.row(fixture))

            begin(fixture)

            #expect(fixture.tabs.count == 2)
            #expect(fixture.session.primarySelection.activeTabID == shell.id)
            #expect(fixture.session.lastActiveTabID(for: Self.row(fixture)) == shell.id)
        }
    }

    @Test func aSetupBehindAnotherRow_makesTheNewTabTheRowsLastTab() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let elsewhere = fixture.session.openTab(container: .project(fixture.project.id))

            begin(fixture)

            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.primarySelection.activeTabID == elsewhere.id)
            #expect(fixture.session.lastActiveTabID(for: Self.row(fixture)) == tab.id)
            // Choosing the row then shows it.
            fixture.session.setActiveContainer(Self.row(fixture))
            #expect(fixture.session.primarySelection.activeTabID == tab.id)
        }
    }

    @Test func aSetupFinishingInAProjectAnotherWindowShows_leavesThatWindowsSelection() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let session = fixture.session
            // The launch's window has gone to another project; a second
            // window shows the session's row, empty.
            let other = session.addOrActivateProject(rootURL: dir.appendingPathComponent("other"), suggestedName: "other")
            session.setActiveContainer(.project(other.id))
            let second = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(Self.row(fixture), in: second)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))

            begin(fixture)

            #expect(fixture.tabs.count == 1)
            #expect(session.selection(second)?.activeContainerID == Self.row(fixture))
            #expect(session.selection(second)?.activeTabID == nil)
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func aSetupWhoseWindowShowsAnotherProject_isBehind() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            let session = fixture.session
            let other = session.addOrActivateProject(rootURL: dir.appendingPathComponent("other"), suggestedName: "other")
            // Asked for on the new row, which would bring the tab to front.
            session.setActiveContainer(Self.row(fixture))
            begin(fixture)
            // The person goes to another project while the setup runs.
            let typing = session.openTab(container: .project(other.id))

            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }

            let tab = try #require(fixture.tabs.first)
            #expect(session.primarySelection.activeTabID == typing.id)
            #expect(session.lastActiveTabID(for: Self.row(fixture)) == tab.id)
        }
    }

    @Test func skippingASetup_afterThePersonMovedToAnotherRow_opensItBehind() async throws {
        try await withTempDir { dir in
            // A step that holds the skip for a while: SIGTERM is ignored
            // until the SIGKILL.
            let (fixture, _) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true, request: Fixture.shell)
            let session = fixture.session
            // The bar was pressed on the new row.
            session.setActiveContainer(Self.row(fixture))

            fixture.store.skipSetup(worktreeID: fixture.worktree.id, in: session)
            // While the step stops, the person goes to a shell of another row.
            let shell = session.openTab(container: .project(fixture.project.id))

            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }

            let tab = try #require(fixture.tabs.first)
            #expect(session.primarySelection.activeTabID == shell.id)
            #expect(session.lastActiveTabID(for: Self.row(fixture)) == tab.id)
        }
    }

    @Test func aSetupFinishingWhileItsWindowIsHidden_selectsItThere() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let session = fixture.session
            let other = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(Self.row(fixture), in: other)
            let asked = session.waitOrigin(in: other)
            // The window is closed (hidden) on the empty row: it still shows
            // the project, and opens again on the new tab.
            session.setWindow(other, isHidden: true)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))

            begin(fixture, in: other)

            let tab = try #require(fixture.tabs.first)
            #expect(session.selection(other)?.activeTabID == tab.id)
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
            // By contrast, a wait the person started from that window while
            // it was shown reads the hiding as leaving it.
            #expect(session.intentAfterWait(from: asked) == .behind)
        }
    }

    @Test func aSetupFinishingInAProjectNoWindowShows_raisesNoWindow() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            let session = fixture.session
            let other = session.addOrActivateProject(rootURL: dir.appendingPathComponent("other"), suggestedName: "other")
            session.setActiveContainer(Self.row(fixture))
            begin(fixture)
            session.setActiveContainer(.project(other.id))
            // From now on a selection of another project's session would
            // switch the window, or bring forward the one that shows it.
            let switches = ProjectSwitchRecorder.connect(to: session)

            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }

            #expect(switches.isUntouched)
            #expect(session.primarySelection.activeContainerID == .project(other.id))
            #expect(session.windowIDs.allSatisfy { session.selection($0)?.shownProjectID != fixture.project.id })
        }
    }

    @Test func setupFinishingAfterThePersonSwitchedToAnotherProject_keepsTheWindowThere() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            let session = fixture.session
            let other = session.addOrActivateProject(rootURL: dir.appendingPathComponent("other"), suggestedName: "other")
            session.setActiveContainer(Self.row(fixture))
            session.primarySelection.projectID = fixture.project.id
            let switches = ProjectSwitchRecorder.connect(to: session)
            begin(fixture)
            // The person switches the window to the other project while the
            // setup runs.
            session.setActiveContainer(.project(other.id))
            #expect(session.primarySelection.shownProjectID == other.id)

            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }

            // The window stays where the person went; the project it left
            // keeps the new tab on the row it was left on, empty then.
            let tab = try #require(fixture.tabs.first)
            #expect(session.primarySelection.shownProjectID == other.id)
            #expect(session.primarySelection.activeContainerID == .project(other.id))
            #expect(session.projectViews[fixture.project.id]?.activeTabID == tab.id)
            #expect(switches.switches.count == 1)
            #expect(switches.raised.isEmpty)
            // Coming back finds it.
            session.setActiveContainer(Self.row(fixture))
            #expect(session.primarySelection.shownProjectID == fixture.project.id)
            #expect(session.primarySelection.activeTabID == tab.id)
        }
    }

    // MARK: - In front, or behind

    @Test func aSetupThatEndsWhileAnEmptyRowIsShown_leavesThatRowShown() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            // The project's own row, with no tab.
            fixture.session.setActiveContainer(.project(fixture.project.id))
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { fixture.hasStarted }
            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.primarySelection.activeContainerID == .project(fixture.project.id))
        }
    }

    @Test func skippingTheSetup_bringsTheAgentToFront_overAShellOfTheRow() async throws {
        try await withTempDir { dir in
            // A step that runs for 30 s, longer than the test waits: only the
            // skip starts the agent.
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("exec sleep 30")])
            let container = ContainerID.worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            let shell = fixture.session.openTab(container: container)
            fixture.begin()
            fixture.store.skipSetup(worktreeID: fixture.worktree.id, in: fixture.session)
            // Once the step has stopped.
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { fixture.tabs.count == 2 }
            let agentTab = try #require(fixture.tabs.first { $0.id != shell.id })
            #expect(fixture.session.primarySelection.activeTabID == agentTab.id)
        }
    }

    @Test func aSetupThatEndsInTheShownRow_bringsTheAgentToFront() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            let container = ContainerID.worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            fixture.session.setActiveContainer(container)
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { fixture.hasStarted }
            #expect(fixture.session.primarySelection.activeContainerID == container)
            #expect(fixture.session.primarySelection.activeTabID == fixture.tabs.first?.id)
        }
    }

    // MARK: - The window it opens in

    @Test func theAgentsTab_opensInTheWindowTheSessionWasAskedForIn() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let other = WorkspaceSessionFixture.addWindow(to: fixture.session)
            let worktree = ContainerID.worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            fixture.session.setActiveContainer(worktree, in: other)
            let primaryBefore = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))

            begin(fixture, in: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }

            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.selection(other)?.activeTabID == tab.id)
            #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func aWindowLookingElsewhere_getsTheTabBehind_andKeepsWhatItShows() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let other = WorkspaceSessionFixture.addWindow(to: fixture.session)
            // The asking window works in a shell of the project's own folder.
            let shell = fixture.session.openTab(container: .project(fixture.project.id), in: other)
            let primaryBefore = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))

            begin(fixture, in: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }

            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.selection(other)?.activeTabID == shell.id)
            #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func aSetupEndingBehind_leavesTheScratchWithTheWindowThatChoseIt() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let session = fixture.session
            let scratch = session.openTab(container: .loose)
            let other = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveTab(scratch.id, in: other)
            // The primary chose the scratch tabs last and draws them.
            session.claimScratch(for: nil)

            begin(fixture, in: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }

            #expect(session.selection(other)?.activeTabID == scratch.id)
            #expect(session.scratchOwnerWindowID == session.primaryWindowID)
            #expect(session.showsScratch(in: nil))
        }
    }

    @Test func aRetry_opensTheTabInTheWindowWhoseBarWasUsed() async throws {
        try await withTempDir { dir in
            let marker = dir.appendingPathComponent("marker")
            let fixture = try await Fixture.make(in: dir, bootstrap: [
                .shorthand("test -f '\(marker.path)' || exit 3")
            ])
            let id = fixture.worktree.id
            let worktree = ContainerID.worktree(projectID: fixture.project.id, worktreeID: id)
            begin(fixture)
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.failure != nil }
            let other = WorkspaceSessionFixture.addWindow(to: fixture.session)
            fixture.session.setActiveContainer(worktree, in: other)

            FileManager.default.createFile(atPath: marker.path, contents: nil)
            fixture.store.retry(worktreeID: id, in: fixture.session, window: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }

            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.selection(other)?.activeTabID == tab.id)
            #expect(fixture.session.primarySelection.activeTabID != tab.id)
        }
    }

    @Test func skippingTheSetup_opensTheTabInTheWindowWhoseBarWasUsed() async throws {
        try await withTempDir { dir in
            let (fixture, _) = try await Fixture.startBlockingSetup(in: dir, request: Fixture.shell)
            let id = fixture.worktree.id
            let worktree = ContainerID.worktree(projectID: fixture.project.id, worktreeID: id)
            let other = WorkspaceSessionFixture.addWindow(to: fixture.session)
            fixture.session.setActiveContainer(worktree, in: other)

            fixture.store.skipSetup(worktreeID: id, in: fixture.session, window: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }

            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.selection(other)?.activeTabID == tab.id)
            #expect(fixture.session.primarySelection.activeTabID != tab.id)
        }
    }

    @Test func aPressThatDoesNothing_leavesTheLaunchInItsWindow() async throws {
        try await withTempDir { dir in
            let (fixture, _) = try await Fixture.startBlockingSetup(in: dir, request: Fixture.shell)
            let id = fixture.worktree.id
            let second = WorkspaceSessionFixture.addWindow(to: fixture.session)
            let third = WorkspaceSessionFixture.addWindow(to: fixture.session)
            // The windows whose bars are pressed show the session's project,
            // as a bar's window does: a launch lands in no window that does
            // not.
            let worktree = ContainerID.worktree(projectID: fixture.project.id, worktreeID: id)
            fixture.session.setActiveContainer(worktree, in: second)
            fixture.session.setActiveContainer(worktree, in: third)
            let before = try #require(fixture.store.launches[id]).windowID

            // Nothing failed: a retry has nothing to do.
            fixture.store.retry(worktreeID: id, in: fixture.session, window: second)
            #expect(try #require(fixture.store.launches[id]).windowID == before)

            // A second skip while the first stops the setup does nothing.
            fixture.store.skipSetup(worktreeID: id, in: fixture.session, window: second)
            fixture.store.skipSetup(worktreeID: id, in: fixture.session, window: third)
            #expect(try #require(fixture.store.launches[id]).windowID == second)

            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }
            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.selection(second)?.activeTabID == tab.id)
        }
    }
}
