// TempGitRepo.swift
// Limpid — disposable git repository under `tmp`, seeded with one empty
// commit so `git` subcommands have a valid HEAD to compare against.

import Foundation
@testable import Limpid

struct TempGitRepo {
    let url: URL

    /// Initialize a temp directory and run `git init` + a seed commit
    /// against it. Throws if the runner has no `git` on PATH or the
    /// temp directory can't be created.
    static func make() async throws -> TempGitRepo {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        let initResult = try await GitProcess.run(["init", "-q", "-b", "main"], cwd: url)
        guard initResult.succeeded else {
            throw NSError(
                domain: "TempGitRepo",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "git init failed: \(initResult.stderr)"]
            )
        }
        // Identity is required before any commit; configure locally so
        // we don't depend on the runner's global git config.
        _ = try await GitProcess.run(["config", "user.email", "test@limpid.invalid"], cwd: url)
        _ = try await GitProcess.run(["config", "user.name", "Limpid Test"], cwd: url)
        let seed = try await GitProcess.run(
            ["commit", "--allow-empty", "-m", "init"],
            cwd: url
        )
        guard seed.succeeded else {
            throw NSError(
                domain: "TempGitRepo",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "seed commit failed: \(seed.stderr)"]
            )
        }
        return TempGitRepo(url: url)
    }

    /// Remove the on-disk directory. Call this from test teardown
    /// (Swift Testing has no XCTest-style `tearDown`; call manually
    /// at end of test or use `defer`).
    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
