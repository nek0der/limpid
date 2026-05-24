// GitWorktreeListTests.swift
// Parser tests for `git worktree list --porcelain` + one smoke test
// that runs the real subcommand against a freshly-initialized temp
// repo (when one is available).

import Foundation
import Testing
@testable import Limpid

@Suite("GitWorktreeList parser")
struct GitWorktreeListParserTests {

    @Test("a single worktree on main is parsed with its head + branch")
    func parse_singleWorktreeOnMain_extractsAllFields() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD abc123abc123abc123abc123abc123abc123abc1
        branch refs/heads/main

        """
        let result = GitWorktreeList.parse(porcelain)
        #expect(result.count == 1)
        #expect(result[0].path.path == "/Users/me/repo")
        #expect(result[0].headSHA == "abc123abc123abc123abc123abc123abc123abc1")
        #expect(result[0].branch == "main")
        #expect(result[0].isDetached == false)
    }

    @Test("multiple worktrees: branch / branch / detached are distinguished")
    func parse_multipleWorktrees_separatesBranchAndDetached() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD aaa
        branch refs/heads/main

        worktree /Users/me/repo-feat
        HEAD bbb
        branch refs/heads/feat-x

        worktree /Users/me/repo-detached
        HEAD ccc
        detached

        """
        let result = GitWorktreeList.parse(porcelain)
        #expect(result.count == 3)
        #expect(result[0].branch == "main")
        #expect(result[1].branch == "feat-x")
        #expect(result[2].branch == nil)
        #expect(result[2].isDetached)
    }

    @Test("locked / prunable flags are surfaced when git emits them")
    func parse_lockedAndPrunableFlags_areSurfaced() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD aaa
        branch refs/heads/main
        locked some-reason

        worktree /Users/me/repo-stale
        HEAD bbb
        branch refs/heads/old
        prunable

        """
        let result = GitWorktreeList.parse(porcelain)
        #expect(result.count == 2)
        #expect(result[0].isLocked)
        #expect(result[1].isPrunable)
    }

    @Test("a bare repo entry is recognized and has no branch / HEAD")
    func parse_bareRepo_setsBareAndOmitsHeadAndBranch() {
        let porcelain = """
        worktree /Users/me/bare.git
        bare

        """
        let result = GitWorktreeList.parse(porcelain)
        #expect(result.count == 1)
        #expect(result[0].isBare)
        #expect(result[0].branch == nil)
        #expect(result[0].headSHA == nil)
    }

    @Test("unknown future fields are ignored without aborting the parse")
    func parse_unknownLine_isIgnored() {
        let porcelain = """
        worktree /tmp/repo
        HEAD aaa
        branch refs/heads/main
        somefuturefield value

        """
        let result = GitWorktreeList.parse(porcelain)
        #expect(result.count == 1)
        #expect(result[0].branch == "main")
    }

    /// Smoke test against a freshly-initialized git repo. Skipped when
    /// `git` is unavailable.
    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func fetch_freshTempRepo_listsTheInitialWorktree() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let worktrees = try await GitWorktreeList.fetch(repoRoot: repo.url)
        #expect(worktrees.count >= 1)
    }
}
