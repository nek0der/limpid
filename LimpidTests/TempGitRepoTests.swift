// TempGitRepoTests.swift
// Limpid — every repository the git fixture makes, its clones included, gets the fixture's local git overrides.

import Foundation
import Testing
@testable import Limpid

@Suite(.timeLimit(.minutes(1)))
struct TempGitRepoTests {
    /// These are the settings `configureForTests` writes that the clones
    /// once lacked.
    static let isolation = [("core.autocrlf", "false"), ("tag.gpgsign", "false"), ("core.excludesFile", "/dev/null")]

    @Test func theRepository_getsTheLocalOverrides() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        for (key, value) in Self.isolation {
            #expect(try await repo.git(["config", "--local", "--get", key]) == value, "\(key)")
        }
    }

    /// The teammate's clone gets these overrides as the repository it moves
    /// on does, though it once lacked them.
    @Test func theTeammatesClone_getsTheLocalOverridesToo() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        _ = try await repo.advance(bare)
        let clone = repo.scratch.appendingPathComponent("\(repo.url.lastPathComponent)-clone")

        for (key, value) in Self.isolation {
            #expect(try await TempGitRepo.git(["config", "--local", "--get", key], in: clone) == value, "\(key)")
        }
    }
}
