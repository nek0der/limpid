// WorkspaceSessionOpenProjectTests.swift
// Weir — covers `WorkspaceSession.openProject(at:)`, the one flow every
// "open a project" gesture shares, and holds the command palette's
// recent-project row to it.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession openProject")
@MainActor
struct WorkspaceSessionOpenProjectTests {
    private typealias Fixture = WorkspaceSessionFixture

    @Test("addProject adds or finds the project and moves no window")
    func addProject_movesNoWindow() async {
        let session = WorkspaceSession()
        let tab = session.openTab(container: .loose)
        let url = Fixture.projectRootURL("open-project")

        let project = await session.addProject(at: url) { $0 }

        #expect(session.project(project.id) != nil)
        #expect(session.primarySelection.activeTabID == tab.id)
        #expect(session.recentProjectPaths.first == url.standardizedFileURL)
        #expect(await session.addProject(at: url) { $0 }.id == project.id)
    }

    // MARK: - Helpers

    /// Stand-in for `GitProcess.resolveMainCheckout(of:)` that leaves
    /// every path alone, so these tests never spawn `git`.
    private static func unchanged(_ url: URL) async -> URL {
        url
    }

    // MARK: - Tabs and activation

    @Test func openProject_newPath_opensTabInProjectAndActivatesIt() async throws {
        let session = WorkspaceSession()
        let scratchTab = session.openTab(container: .loose)

        let project = await session.openProject(at: Fixture.projectRootURL("open-project"), resolveMainCheckout: Self.unchanged)

        let projectTabs = session.tabs.filter { $0.projectID == project.id }
        #expect(projectTabs.count == 1)
        let tab = try #require(projectTabs.first)
        #expect(session.primarySelection.activeTabID == tab.id)
        #expect(session.primarySelection.activeTabID != scratchTab.id)
        #expect(session.primarySelection.activeContainerID == .project(project.id))
    }

    @Test func openProject_existingProjectWithTabs_activatesWithoutOpeningAnother() async {
        let session = WorkspaceSession()
        let url = Fixture.projectRootURL("open-project")
        let project = session.addOrActivateProject(rootURL: url)
        let projectTab = session.openTab(container: .project(project.id))
        session.openTab(container: .loose)
        let tabCount = session.tabs.count

        let reopened = await session.openProject(at: url, resolveMainCheckout: Self.unchanged)

        #expect(reopened.id == project.id)
        #expect(session.projects.count == 1)
        #expect(session.tabs.count == tabCount)
        #expect(session.primarySelection.activeTabID == projectTab.id)
    }

    @Test func openProject_existingProjectWithoutTabs_opensExactlyOneTab() async {
        let session = WorkspaceSession()
        let url = Fixture.projectRootURL("open-project")
        let project = session.addOrActivateProject(rootURL: url)

        await session.openProject(at: url, resolveMainCheckout: Self.unchanged)

        #expect(session.tabs.filter { $0.projectID == project.id }.count == 1)
        #expect(session.primarySelection.activeContainerID == .project(project.id))
    }

    // MARK: - Main-checkout resolution

    @Test func openProject_resolvedPath_becomesRootAndReusesTheMainProject() async {
        let session = WorkspaceSession()
        let main = Fixture.projectRootURL("open-project").appendingPathComponent("repo")
        let linked = Fixture.projectRootURL("open-project").appendingPathComponent("repo-feature")
        let mainProject = session.addOrActivateProject(rootURL: main)

        let opened = await session.openProject(at: linked) { _ in main }

        #expect(opened.id == mainProject.id)
        #expect(session.projects.count == 1)
        #expect(session.recentProjectPaths.first == main.standardizedFileURL)
    }

    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func openProject_linkedWorktreePath_opensTheMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let linkedPath = try await repo.addLinkedWorktree(branch: "feature")
        let session = WorkspaceSession()

        let project = await session.openProject(at: linkedPath)

        #expect(project.rootURL.standardizedFileURL == repo.url.standardizedFileURL)
        #expect(session.projects.count == 1)
        #expect(session.primarySelection.activeContainerID == .project(project.id))
    }

    // MARK: - Command palette

    /// The palette lists only recent projects that are not open, so its
    /// row always takes the new-project path that used to leave the user
    /// without a tab.
    @Test func paletteOpenRecentProject_followsTheSharedFlow() async throws {
        try await withTempDir { dir in
            let folder = dir.appendingPathComponent("recent", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = WorkspaceSession()
            session.openTab(container: .loose)
            let frecency = FrecencyStore(directory: dir.appendingPathComponent("frecency"))

            CommandPaletteActions.executeCommandPaletteAction(
                .openRecentProject(folder),
                session: session,
                attention: AttentionState(),
                registry: RecordingSurfaceRegistry(),
                commands: RecordingWindowCommands(),
                frecencyStore: frecency,
                toastCenter: ToastCenter(),
                minPaneSize: 0,
                window: session.primaryWindowID
            )
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !session.projects.isEmpty }
            // Write the palette's frecency hit now so no debounced save
            // lands after the directory is gone.
            frecency.flushSynchronously()

            let project = try #require(session.projects.first)
            #expect(project.rootURL.standardizedFileURL == folder.standardizedFileURL)
            #expect(session.tabs.filter { $0.projectID == project.id }.count == 1)
            #expect(session.primarySelection.activeContainerID == .project(project.id))
        }
    }
}
