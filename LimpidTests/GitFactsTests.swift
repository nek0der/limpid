// GitFactsTests.swift
// Limpid — what a session's folder holds toward a pull request, read from a real repository.

import Foundation
import Testing
@testable import Limpid

@Suite(.tags(.smoke), .timeLimit(.minutes(1)))
struct GitFactsTests {
    @Test func aRepositoryWithNoRemote_countsAgainstItsLocalMain_andHasNoUnpushedCount() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        let onMain = try await read(repo.url)
        #expect(onMain.branch == "main")
        #expect(onMain.base == GitFacts.Base(ref: "main"))
        #expect(onMain.isOnBase)
        #expect(onMain.commitsNotOnBase == 0)
        #expect(onMain.unpushedCommits == nil)
        #expect(onMain.uncommittedFiles == 0)

        try await repo.git(["switch", "-q", "-c", "feat/x"])
        try await commit("a.txt", at: repo.url)
        try await commit("b.txt", at: repo.url)
        let onBranch = try await read(repo.url)
        #expect(!onBranch.isOnBase)
        #expect(onBranch.commitsNotOnBase == 2)
    }

    @Test func uncommittedFiles_countEachUntrackedFile_andEachChangedOne() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await commit("tracked.txt", at: repo.url)

        // Two files in a new folder are two, not the folder as one.
        let folder = repo.url.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: folder.appendingPathComponent("two.txt"))
        try Data("changed".utf8).write(to: repo.url.appendingPathComponent("tracked.txt"))

        let facts = try await read(repo.url)
        #expect(facts.uncommittedFiles == 3)
    }

    @Test func withARemote_theBaseIsOriginsDefault_andUnpushedCommitsAreThoseNoRemoteHas() async throws {
        let repo = try await TempGitRepo.make()
        let remote = try await TempGitRepo.make()
        defer {
            repo.cleanup()
            remote.cleanup()
        }
        try await remote.git(["config", "receive.denyCurrentBranch", "ignore"])
        try await repo.git(["remote", "add", "origin", remote.url.path])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["remote", "set-head", "origin", "main"])
        try await repo.git(["switch", "-q", "-c", "feat/x", "origin/main"])
        try await commit("a.txt", at: repo.url)
        try await commit("b.txt", at: repo.url)

        let unpushed = try await read(repo.url)
        #expect(unpushed.base == GitFacts.Base(ref: "origin/main"))
        #expect(unpushed.base?.name == "main")
        #expect(unpushed.commitsNotOnBase == 2)
        #expect(unpushed.unpushedCommits == 2)

        try await repo.git(["push", "-q", "-u", "origin", "feat/x"])
        let pushed = try await read(repo.url)
        #expect(pushed.unpushedCommits == 0)
        // Pushed is not merged: the pull request would still carry them.
        #expect(pushed.commitsNotOnBase == 2)

        // Past its upstream, counted against the upstream.
        try await commit("c.txt", at: repo.url)
        #expect(try await read(repo.url).unpushedCommits == 1)

        // The upstream deleted on the remote as its request merged: there
        // is nothing to count against, which is not "all unpushed".
        try await repo.git(["push", "-q", "origin", "--delete", "feat/x"])
        try await repo.git(["fetch", "-q", "--prune", "origin"])
        let gone = try await read(repo.url)
        #expect(gone.unpushedCommits == nil)
    }

    @Test func aBranchTrackingTheDefaultBranch_isPushedOnceARemoteHasItsCommits() async throws {
        let repo = try await TempGitRepo.make()
        let remote = try await TempGitRepo.make()
        defer {
            repo.cleanup()
            remote.cleanup()
        }
        try await repo.git(["remote", "add", "origin", remote.url.path])
        try await repo.git(["fetch", "-q", "origin"])
        // Made from origin/main, the branch tracks origin/main, as an
        // agent's worktree often does.
        try await repo.git(["switch", "-q", "--track", "-c", "feat/x", "origin/main"])
        try await commit("a.txt", at: repo.url)
        #expect(try await read(repo.url).unpushedCommits == 1)

        // Pushed without -u: still ahead of its upstream, but on a remote.
        try await repo.git(["push", "-q", "origin", "feat/x"])
        #expect(try await read(repo.url).unpushedCommits == 0)
    }

    @Test func aFolderThatIsNoWorkTree_hasNoFacts() async throws {
        try await withTempDir { folder in
            #expect(await ReviewGit.facts(at: folder) == .notWorkTree)
        }
    }

    /// The facts at `folder`, which a real repository must give.
    private func read(_ folder: URL) async throws -> GitFacts {
        guard case let .facts(facts) = await ReviewGit.facts(at: folder) else {
            throw NoFacts(folder: folder)
        }
        return facts
    }

    private func commit(_ name: String, at folder: URL) async throws {
        try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        try await TempGitRepo.git(["add", "--", name], in: folder)
        try await TempGitRepo.git(["commit", "-q", "-m", name], in: folder)
    }
}

private struct NoFacts: Error {
    let folder: URL
}
