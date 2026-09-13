// GitProcessTests.swift
// Limpid — smoke checks that we can shell out to `git` from the test host.
// These require a real .git directory; they no-op cleanly otherwise via
// `RepoFixture.hasLocalRepo`.

import Foundation
import Testing
@testable import Limpid

@Suite("GitProcess smoke", .tags(.smoke))
struct GitProcessSmokeTests {

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func run_gitVersion_reportsGitVersionString() async throws {
        let root = try #require(RepoFixture.limpidRoot)
        let result = try await GitProcess.run(["--version"], cwd: root)
        #expect(result.succeeded, "git --version should succeed: \(result.stderr)")
        #expect(result.stdout.contains("git version"))
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func isGitRepository_returnsTrue_forLimpidRoot() async throws {
        let root = try #require(RepoFixture.limpidRoot)
        let isRepo = await GitProcess.isGitRepository(root)
        #expect(isRepo)
    }

    @Test
    func isGitRepository_returnsFalse_forTmpDirectory() async {
        let isRepo = await GitProcess.isGitRepository(URL(fileURLWithPath: "/tmp"))
        #expect(isRepo == false)
    }

    @Test
    func removeWorktree_withInitializedSubmodule_requiresForce() async throws {
        let repository = try await TempGitRepo.make()
        let submodule = try await TempGitRepo.make()
        let linkedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-linked-\(UUID().uuidString)")
        defer {
            repository.cleanup()
            submodule.cleanup()
            try? FileManager.default.removeItem(at: linkedPath)
        }

        let addSubmodule = try await GitProcess.run(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "--",
                submodule.url.path, "deps/submodule"
            ],
            cwd: repository.url
        )
        try #require(addSubmodule.succeeded, "git submodule add failed: \(addSubmodule.stderr)")
        let commit = try await GitProcess.run(
            ["commit", "-m", "Add test submodule"],
            cwd: repository.url
        )
        try #require(commit.succeeded, "git commit failed: \(commit.stderr)")
        let addWorktree = try await GitProcess.run(
            ["worktree", "add", "-b", "linked", "--", linkedPath.path],
            cwd: repository.url
        )
        try #require(addWorktree.succeeded, "git worktree add failed: \(addWorktree.stderr)")
        let initialize = try await GitProcess.run(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
            cwd: linkedPath
        )
        try #require(initialize.succeeded, "git submodule update failed: \(initialize.stderr)")
        let linkedSubmodule = linkedPath.appendingPathComponent("deps/submodule")
        let localCommit = try await GitProcess.run(
            [
                "-c", "user.name=Limpid Tests",
                "-c", "user.email=tests@limpid.invalid",
                "commit", "--allow-empty", "-m", "Local-only submodule commit"
            ],
            cwd: linkedSubmodule
        )
        try #require(localCommit.succeeded, "local submodule commit failed: \(localCommit.stderr)")
        let resolveGitDirectory = try await GitProcess.run(
            ["rev-parse", "--absolute-git-dir"],
            cwd: linkedSubmodule
        )
        try #require(resolveGitDirectory.succeeded, "git-dir lookup failed: \(resolveGitDirectory.stderr)")
        let submoduleGitDirectory = resolveGitDirectory.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(FileManager.default.fileExists(atPath: submoduleGitDirectory))

        let regularRemoval = try await GitProcess.removeWorktree(
            repoRoot: repository.url,
            path: linkedPath,
            force: false
        )
        #expect(!regularRemoval.succeeded)
        #expect(regularRemoval.stderr.contains("working trees containing submodules"))

        let forcedRemoval = try await GitProcess.removeWorktree(
            repoRoot: repository.url,
            path: linkedPath,
            force: true
        )
        #expect(forcedRemoval.succeeded, "forced removal failed: \(forcedRemoval.stderr)")
        #expect(!FileManager.default.fileExists(atPath: submoduleGitDirectory))
    }
}
