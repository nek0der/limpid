// CheckoutNameTests.swift
// Weir — a checkout named by its branch, with one fallback, and the place a tab's row is.

import Foundation
import Testing
@testable import Weir

@MainActor
struct CheckoutNameTests {
    @Test func aDetachedMainCheckout_isStillARepository() {
        let root = URL(fileURLWithPath: "/tmp/weir")
        // On a branch, detached at a commit, and a folder git does not know.
        #expect(CheckoutName.isRepository(Project(name: "weir", rootURL: root, mainBranchName: "main", mainHeadSHA: "abc1234")))
        #expect(CheckoutName.isRepository(Project(name: "weir", rootURL: root, mainBranchName: nil, mainHeadSHA: "abc1234")))
        #expect(!CheckoutName.isRepository(Project(name: "weir", rootURL: root)))
        // A worktree found by git says so too, before the main folder's sync.
        let worktree = Worktree(label: "feat", workingDirectory: root.appendingPathComponent("feat"), origin: .gitWorktree)
        #expect(CheckoutName.isRepository(Project(name: "weir", rootURL: root, worktrees: [worktree])))
    }

    @Test func aCheckout_isNamedByItsBranch_withOneFallbackEverywhere() {
        let worktree = Worktree(label: "spike", workingDirectory: URL(fileURLWithPath: "/tmp/spike"), origin: .gitWorktree)
        var named = worktree
        named.gitRef = GitRef(branchName: "feat/spike")
        var detached = worktree
        detached.gitRef = GitRef(branchName: "")

        #expect(CheckoutName.of(worktree) == "spike")
        #expect(CheckoutName.of(named) == "feat/spike")
        #expect(CheckoutName.of(detached) == "spike", "an empty branch name is no name")
        #expect(CheckoutName.of(Project(name: "notes", rootURL: URL(fileURLWithPath: "/tmp/notes"))) == nil)
        #expect(CheckoutName.of(.loose, in: WorkspaceSession()) == nil)
    }

    @Test func aTabsPlace_isTheScratchTabs_aCheckoutByName_orNoneOnceItsProjectIsGone() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        var worktree = Worktree(
            label: "supervision-ui",
            workingDirectory: project.rootURL.appendingPathComponent("supervision-ui"),
            origin: .gitWorktree
        )
        worktree.gitRef = GitRef(branchName: "feat/supervision-ui")
        session.projects[index].worktrees = [worktree]

        #expect(CheckoutName.place(of: .loose, in: session) == .scratch)
        #expect(
            CheckoutName.place(of: .worktree(projectID: project.id, worktreeID: worktree.id), in: session)
                == .named("feat/supervision-ui")
        )
        #expect(
            CheckoutName.place(of: .project(project.id), in: session) == .named(project.rootURL.lastPathComponent),
            "a project's folder with no branch yet, by its folder's name"
        )
        session.projects[index].mainBranchName = "main"
        #expect(CheckoutName.place(of: .project(project.id), in: session) == .named("main"))
        #expect(CheckoutName.place(of: .project(UUID()), in: session) == nil, "a project that is gone is no scratch tab")
        #expect(CheckoutName.place(of: .worktree(projectID: project.id, worktreeID: UUID()), in: session) == .named("main"))
    }
}
