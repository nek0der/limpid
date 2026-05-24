// GitProcessTests.swift
// Smoke checks that we can shell out to `git` from the test host. These
// require a real .git directory; they no-op cleanly otherwise via
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
}
