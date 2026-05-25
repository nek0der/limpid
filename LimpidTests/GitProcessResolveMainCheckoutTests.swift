// GitProcessResolveMainCheckoutTests.swift
// Limpid — covers `GitProcess.resolveMainCheckout(of:)`, the helper
// that protects "Add Project" from registering a linked worktree as a
// new Project rootURL. Smoke-style: spins up a real on-disk git repo
// via `TempGitRepo`, adds a real linked worktree, then exercises every
// branch of the resolver. Gated by `RepoFixture.hasLocalRepo` because
// the suite needs `git` on PATH.

import Foundation
import Testing
@testable import Limpid

@Suite("GitProcess resolveMainCheckout", .tags(.smoke))
struct GitProcessResolveMainCheckoutTests {

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forNonGitDirectory() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-non-git-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = await GitProcess.resolveMainCheckout(of: tmp)

        #expect(resolved.standardizedFileURL == tmp.standardizedFileURL)
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func resolveMainCheckout_returnsURLUnchanged_forMainCheckoutRoot() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        let resolved = await GitProcess.resolveMainCheckout(of: repo.url)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func resolveMainCheckout_returnsURLUnchanged_forSubdirectoryOfMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let subdir = repo.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let resolved = await GitProcess.resolveMainCheckout(of: subdir)

        // Subdirectories under a working tree are an intentional
        // anchor — the resolver must not promote them.
        #expect(resolved.standardizedFileURL == subdir.standardizedFileURL)
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func resolveMainCheckout_promotesLinkedWorktreeRoot_toMainCheckout() async throws {
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

        let resolved = await GitProcess.resolveMainCheckout(of: linkedPath)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
    }
}
