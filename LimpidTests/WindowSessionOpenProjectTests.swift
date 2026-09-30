// WindowSessionOpenProjectTests.swift
// Limpid — covers `WindowSession.openProject(at:)`, the one flow every
// "open a project" gesture shares, and holds the command palette's
// recent-project row to it.

import Foundation
import Testing
@testable import Limpid

@Suite("WindowSession openProject")
@MainActor
struct WindowSessionOpenProjectTests {

    // MARK: - Helpers

    /// Unique tmp URL per call. Only the in-memory tests use it, and
    /// they inject the resolver, so nothing reads the path from disk.
    private func tmpURL(_ suffix: String = "") -> URL {
        let base = "/tmp/limpid-open-project-\(UUID().uuidString)"
        return URL(fileURLWithPath: suffix.isEmpty ? base : "\(base)/\(suffix)")
    }

    /// Stand-in for `GitProcess.resolveMainCheckout(of:)` that leaves
    /// every path alone, so these tests never spawn `git`.
    private static func unchanged(_ url: URL) async -> URL {
        url
    }

    /// Poll `condition` every 20 ms for up to ten seconds. The palette
    /// starts the flow in an unstructured task, so its test has nothing
    /// to await directly.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Tabs and activation

    @Test func openProject_newPath_opensTabInProjectAndActivatesIt() async throws {
        let session = WindowSession()
        let group = session.addGroup()
        let groupTab = session.openTab(container: .group(group.id))

        let project = await session.openProject(at: tmpURL(), resolveMainCheckout: Self.unchanged)

        let projectTabs = session.tabs.filter { $0.projectID == project.id }
        #expect(projectTabs.count == 1)
        let tab = try #require(projectTabs.first)
        #expect(session.activeTabID == tab.id)
        #expect(session.activeTabID != groupTab.id)
        #expect(session.activeContainerID == .project(project.id))
    }

    @Test func openProject_existingProjectWithTabs_activatesWithoutOpeningAnother() async {
        let session = WindowSession()
        let url = tmpURL()
        let project = session.addOrActivateProject(rootURL: url)
        let projectTab = session.openTab(container: .project(project.id))
        let group = session.addGroup()
        session.openTab(container: .group(group.id))
        let tabCount = session.tabs.count

        let reopened = await session.openProject(at: url, resolveMainCheckout: Self.unchanged)

        #expect(reopened.id == project.id)
        #expect(session.projects.count == 1)
        #expect(session.tabs.count == tabCount)
        #expect(session.activeTabID == projectTab.id)
    }

    @Test func openProject_existingProjectWithoutTabs_opensExactlyOneTab() async {
        let session = WindowSession()
        let url = tmpURL()
        let project = session.addOrActivateProject(rootURL: url)

        await session.openProject(at: url, resolveMainCheckout: Self.unchanged)

        #expect(session.tabs.filter { $0.projectID == project.id }.count == 1)
        #expect(session.activeContainerID == .project(project.id))
    }

    @Test func openProject_foldedProjectsSection_unfoldsIt() async {
        let session = WindowSession()
        session.projectsSectionExpanded = false

        await session.openProject(at: tmpURL(), resolveMainCheckout: Self.unchanged)

        #expect(session.projectsSectionExpanded)
    }

    // MARK: - Main-checkout resolution

    @Test func openProject_resolvedPath_becomesRootAndReusesTheMainProject() async {
        let session = WindowSession()
        let main = tmpURL("repo")
        let linked = tmpURL("repo-feature")
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
        let linkedPath = repo.url
            .deletingLastPathComponent()
            .appendingPathComponent("\(repo.url.lastPathComponent)-feature")
        defer { try? FileManager.default.removeItem(at: linkedPath) }
        let add = try await GitProcess.run(
            ["worktree", "add", "-b", "feature", linkedPath.path],
            cwd: repo.url
        )
        try #require(add.succeeded, "git worktree add failed: \(add.stderr)")
        let session = WindowSession()

        let project = await session.openProject(at: linkedPath)

        #expect(project.rootURL.standardizedFileURL == repo.url.standardizedFileURL)
        #expect(session.projects.count == 1)
        #expect(session.activeContainerID == .project(project.id))
    }

    // MARK: - Command palette

    /// The palette lists only recent projects that are not open, so its
    /// row always takes the new-project path that used to leave the user
    /// without a tab.
    @Test func paletteOpenRecentProject_followsTheSharedFlow() async throws {
        // `withTempDir`'s async overload takes a non-Sendable closure that
        // a MainActor suite cannot hand off, so we manage the directory
        // here.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-open-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("recent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = WindowSession()
        session.projectsSectionExpanded = false
        let group = session.addGroup()
        session.openTab(container: .group(group.id))
        let frecency = FrecencyStore(directory: dir.appendingPathComponent("frecency"))

        CommandPaletteActions.executeCommandPaletteAction(
            .openRecentProject(folder),
            session: session,
            attention: AttentionState(),
            registry: RecordingSurfaceRegistry(),
            frecencyStore: frecency,
            toastCenter: ToastCenter(),
            minPaneSize: 0
        )
        try await Self.waitUntil { !session.projects.isEmpty }
        // Write the palette's frecency hit now so no debounced save
        // lands after the directory is gone.
        frecency.flushSynchronously()

        let project = try #require(session.projects.first)
        #expect(project.rootURL.standardizedFileURL == folder.standardizedFileURL)
        #expect(session.tabs.filter { $0.projectID == project.id }.count == 1)
        #expect(session.activeContainerID == .project(project.id))
        #expect(session.projectsSectionExpanded)
    }
}
