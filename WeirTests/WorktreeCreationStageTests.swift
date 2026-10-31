// WorktreeCreationStageTests.swift
// Weir — creating a worktree in stages: each failure named by its stage, and a retry that makes nothing twice.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeCreationStageTests {
    private static func session(bootstrap: [BootstrapItem] = []) -> (WorkspaceSession, Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].bootstrap = bootstrap
        return (session, session.projects[index])
    }

    /// The test's own `PATH`: no login shell is started.
    private nonisolated static let path = ProcessInfo.processInfo.environment["PATH"]

    private static func failure(_ body: () async throws -> some Any) async -> CreateWorktreeError? {
        await WorktreeFixture.failure(CreateWorktreeError.self, of: body)
    }

    @Test func aBranchThatCannotBeMade_isTheWorktreeStage_andLeavesNothing() async {
        let (session, project) = Self.session()
        let git = FakeGit()
        git.nextBranchResult = .failure("fatal: a branch named 'feat/x' already exists")
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "main", newBranchName: "feat/x", openTab: false,
                git: git
            )
        }
        #expect(error?.stage == .creatingWorktree)
        #expect(error?.leavesWorktree == false)
        #expect(error?.logTail == "fatal: a branch named 'feat/x' already exists")
        guard case .gitFailed = error else {
            Issue.record("a branch that was never made was reported as left behind: \(String(describing: error))")
            return
        }
        #expect(git.createCalls.isEmpty)
        #expect(session.project(project.id)?.worktrees.isEmpty == true)
    }

    @Test func partialBranchSuccess_isReusable() async throws {
        let (session, project) = Self.session()
        let git = FakeGit()
        git.nextCreateResult = .failure("fatal: could not create work tree dir")
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "main", newBranchName: "feat/x", openTab: false,
                git: git
            )
        }
        guard case let .gitFailedLeavingBranch(_, branch) = error else {
            Issue.record("expected the branch left behind, got \(String(describing: error))")
            return
        }
        #expect(branch == "feat/x")

        // The retry uses the branch as an existing one: no second branch.
        git.nextCreateResult = .success()
        let worktree = try await session.createGitWorktree(
            projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "feat/x", newBranchName: nil, openTab: false, git: git
        )
        #expect(git.branchCalls.count == 1)
        #expect(git.createCalls.last?.baseBranch == "feat/x")
        #expect(session.project(project.id)?.worktrees.map(\.id) == [worktree.id])
    }

    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func partialBranchSuccess_isReusable_inARealRepository() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "real")
        // A file where the worktree's parent folder should be: git makes the
        // branch, then cannot add the worktree.
        let blocker = repo.url.appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id,
                path: blocker.appendingPathComponent("wt"),
                baseBranch: "main",
                newBranchName: "feat/real",
                openTab: false
            )
        }
        guard case let .gitFailedLeavingBranch(_, branch) = error else {
            Issue.record("expected the branch left behind, got \(String(describing: error))")
            return
        }
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: repo.url.appendingPathComponent("wt"),
            baseBranch: branch,
            newBranchName: nil,
            openTab: false
        )
        #expect(worktree.gitRef?.branchName == "feat/real")
    }

    @Test func retryAfterSetupFailure_doesNotCreateSecondWorktree() async throws {
        let marker = WorktreeFixture.freshPath()
        defer { try? FileManager.default.removeItem(at: marker) }
        let (session, project) = Self.session(bootstrap: [
            .shorthand("echo first"),
            .shorthand("test -f '\(marker.path)' || { echo 'missing marker' >&2; exit 3; }")
        ])
        let git = FakeGit()
        git.createsDirectoryOnSuccess = true
        let path = WorktreeFixture.freshPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // The worktree stage ends with the row; the setup is the next one.
        let worktree = try await session.createGitWorktree(
            projectID: project.id, path: path, baseBranch: "main", newBranchName: "feat/x", openTab: false, git: git
        )
        let error = await Self.failure {
            try await session.runSetup(projectID: project.id, worktreeID: worktree.id, path: { Self.path })
        }
        #expect(error?.stage == .setup(stepIndex: 1))
        #expect(error?.leavesWorktree == true)
        #expect(error?.logTail == "missing marker")
        #expect(session.project(project.id)?.worktrees.map(\.id) == [worktree.id])

        FileManager.default.createFile(atPath: marker.path, contents: nil)
        try await session.runSetup(projectID: project.id, worktreeID: worktree.id, from: 1, path: { Self.path })
        #expect(git.createCalls.count == 1)
        #expect(session.project(project.id)?.worktrees.count == 1)
        // Past the last command there is nothing to run.
        try await session.runSetup(projectID: project.id, worktreeID: worktree.id, from: 5, path: { Self.path })
    }

    @Test func aBranchNameGitWouldReadAsAnOption_isRefused_beforeGitRuns() async {
        let (session, project) = Self.session()
        let git = FakeGit()
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "develop", newBranchName: "-D", openTab: false,
                git: git
            )
        }
        #expect(error?.stage == .creatingWorktree)
        guard case .invalidBranchName("-D") = error else {
            Issue.record("not refused: \(String(describing: error))")
            return
        }
        #expect(git.branchCalls.isEmpty)
    }

    @Test func gitsWords_keepTheirEnd_asALogDoes() {
        let long = String(repeating: "x", count: 20000) + "the end"
        let tail = CreateWorktreeError.tail(long)
        #expect(tail.hasSuffix("the end"))
        #expect(tail.utf8.count <= WorktreeSetup.logTailBytes)
        #expect(CreateWorktreeError.tail("  short \n") == "short")
    }
}
