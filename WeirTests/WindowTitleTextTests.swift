// WindowTitleTextTests.swift
// Weir — the supervision window's title: the project and the branch checked out where it is.

import Foundation
import Testing
@testable import Weir

@MainActor
struct WindowTitleTextTests {
    @Test func aProject_isNamedWithTheBranchItsCheckoutIsOn() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })

        #expect(WindowTitleText.projectAndBranch(.project(project.id), in: session) == "weir")

        session.projects[index].mainBranchName = "main"
        #expect(WindowTitleText.projectAndBranch(.project(project.id), in: session) == "weir — main")
    }

    @Test func aWorktree_isNamedByItsBranch_orItsLabelBeforeTheBranchIsKnown() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        var worktree = Worktree(
            label: "supervision-ui",
            workingDirectory: project.rootURL.appendingPathComponent("supervision-ui"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [worktree]
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)

        #expect(WindowTitleText.projectAndBranch(container, in: session) == "weir — supervision-ui")

        worktree.gitRef = GitRef(branchName: "feat/supervision-ui")
        session.projects[index].worktrees = [worktree]
        #expect(WindowTitleText.projectAndBranch(container, in: session) == "weir — feat/supervision-ui")
    }

    @Test func aWindowOutsideAnyProject_isNamedByTheApp() {
        let session = WorkspaceSession()

        #expect(WindowTitleText.projectAndBranch(.loose, in: session) == "Weir")
        #expect(WindowTitleText.projectAndBranch(.project(UUID()), in: session) == "Weir", "a project that is gone")
    }

    @Test func theScratchTabs_areNamedByTheWindowsProject() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")

        #expect(WindowTitleText.projectAndBranch(.loose, shownProjectID: project.id, in: session) == "weir")
        #expect(WindowTitleText.projectAndBranch(.loose, shownProjectID: nil, in: session) == "Weir", "a window that shows nothing")
        #expect(WindowTitleText.projectAndBranch(.loose, shownProjectID: UUID(), in: session) == "Weir", "a project that is gone")
    }
}
