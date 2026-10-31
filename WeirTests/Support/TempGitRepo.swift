// TempGitRepo.swift
// Weir — disposable git repository under `tmp`, seeded with one empty
// commit so `git` subcommands have a valid HEAD to compare against.

import Foundation
import Testing
@testable import Weir

struct TempGitRepo {
    /// What a `git` command a fixture runs said when it failed.
    struct GitFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let stderr: String

        var description: String {
            "git \(arguments.joined(separator: " ")) failed: \(stderr)"
        }
    }

    /// The repository's top. It sits in a scratch folder of its own, never
    /// directly in the temporary directory: code that resolves a git path
    /// against the wrong base (`.git` read relative to a root URL with no
    /// trailing slash lands in the root's parent) then writes into this
    /// repository's scratch, where `cleanup` catches it, rather than into a
    /// `$TMPDIR/.git` every later run shares.
    let url: URL

    /// The folder holding the repository and everything placed beside it.
    var scratch: URL {
        url.deletingLastPathComponent()
    }

    /// Initialize a temp directory and run `git init` + a seed commit
    /// against it. Throws if the runner has no `git` on PATH or the
    /// temp directory can't be created.
    static func make() async throws -> TempGitRepo {
        // The repository folder has the unique name, so a project made from
        // it gets a unique name; the folder around it has the same name only
        // to keep it unique.
        let name = "weir-git-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try await initialize(url)
        try await git(["commit", "-q", "--allow-empty", "-m", "init"], in: url)
        return TempGitRepo(url: url)
    }

    /// Runs `git init` in `directory`, which must exist, and configures the
    /// repository with the local overrides of `configureForTests`. The empty
    /// template directory keeps a template's hooks out of `.git` too.
    static func initialize(_ directory: URL) async throws {
        try await git(["-c", "init.templateDir=", "init", "-q", "-b", "main"], in: directory)
        try await configureForTests(directory)
    }

    /// Writes local settings that override the parts of the developer's own
    /// git configuration a test would trip on, into the repository at
    /// `directory`, one made by `initialize` or a clone a fixture made.
    /// Any other global setting still applies.
    ///
    /// The settings are written to the repository rather than passed per
    /// command so that they hold for every later command in it, the ones the
    /// code under test runs included. Without them a machine with
    /// `commit.gpgsign` on stops each commit on a signing prompt, a global
    /// hooks path runs the developer's hooks on every commit, and a global
    /// excludes file hides files a test expects Git to report. A clone needs
    /// every one of them as much as the first repository does: a global
    /// excludes file that ignores the file a clone adds fails that `git add`.
    /// The `git clone` itself still runs under the global configuration,
    /// since the repository it writes these into does not exist before it.
    static func configureForTests(_ directory: URL) async throws {
        for (key, value) in [
            ("core.autocrlf", "false"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
            ("core.excludesFile", "/dev/null"), ("core.hooksPath", "/dev/null"),
            ("user.email", "test@weir.invalid"), ("user.name", "Weir Test")
        ] {
            try await git(["config", key, value], in: directory)
        }
    }

    /// Runs `git` in `directory`, throwing what it said if it failed, and
    /// answers its output without the trailing newline.
    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await GitProcess.run(arguments, cwd: directory)
        guard result.succeeded else {
            throw GitFailure(arguments: arguments, stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `git` in this repository; see `git(_:in:)`.
    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        try await Self.git(arguments, in: url)
    }

    /// Adds a linked worktree on a new `branch`, beside the repository, and
    /// answers its folder. `cleanup` removes it with the repository.
    @discardableResult
    func addLinkedWorktree(branch: String) async throws -> URL {
        let linked = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-\(branch)")
        try await git(["worktree", "add", "-q", "-b", branch, "--", linked.path])
        return linked
    }

    /// Removes the scratch folder: the repository, and every linked
    /// worktree, origin, or clone put beside it. Call this from test
    /// teardown (Swift Testing has no XCTest-style `tearDown`; call manually
    /// at end of test or use `defer`).
    ///
    /// A `.git` beside the repository is a git path some code resolved
    /// against the repository's parent instead of asking git for an absolute
    /// one, and the test that ran that code fails here.
    func cleanup(sourceLocation: SourceLocation = #_sourceLocation) {
        let stray = scratch.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: stray.path) {
            Issue.record("a git path resolved outside the repository: \(stray.path)", sourceLocation: sourceLocation)
        }
        try? FileManager.default.removeItem(at: scratch)
    }
}
