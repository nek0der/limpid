// WindowTitleTextTests.swift
// Limpid — the supervision window's title: the project and the branch checked out where it is.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct WindowTitleTextTests {
    @Test func aProject_isNamedWithTheBranchItsCheckoutIsOn() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })

        #expect(WindowTitleText.projectAndBranch(.project(project.id), in: session) == "limpid")

        session.projects[index].mainBranchName = "main"
        #expect(WindowTitleText.projectAndBranch(.project(project.id), in: session) == "limpid — main")
    }

    @Test func aWorktree_isNamedByItsBranch_orItsLabelBeforeTheBranchIsKnown() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        var worktree = Worktree(
            label: "supervision-ui",
            workingDirectory: project.rootURL.appendingPathComponent("supervision-ui"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [worktree]
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)

        #expect(WindowTitleText.projectAndBranch(container, in: session) == "limpid — supervision-ui")

        worktree.gitRef = GitRef(branchName: "feat/supervision-ui")
        session.projects[index].worktrees = [worktree]
        #expect(WindowTitleText.projectAndBranch(container, in: session) == "limpid — feat/supervision-ui")
    }

    @Test func aWindowOutsideAnyProject_isNamedByTheApp() {
        let session = WorkspaceSession()

        #expect(WindowTitleText.projectAndBranch(.loose, in: session) == "Limpid")
        #expect(WindowTitleText.projectAndBranch(.project(UUID()), in: session) == "Limpid", "a project that is gone")
    }

    @Test func theScratchTabs_areNamedByTheWindowsProject() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")

        #expect(WindowTitleText.projectAndBranch(.loose, shownProjectID: project.id, in: session) == "limpid")
        #expect(WindowTitleText.projectAndBranch(.loose, shownProjectID: nil, in: session) == "Limpid", "a window that shows nothing")
        #expect(WindowTitleText.projectAndBranch(.loose, shownProjectID: UUID(), in: session) == "Limpid", "a project that is gone")
    }
}
