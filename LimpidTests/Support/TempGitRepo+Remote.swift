// TempGitRepo+Remote.swift
// Limpid — a bare repository beside a temp repository as its origin, and a second clone that moves it on, for the suites about fetching.

import Foundation
@testable import Limpid

extension TempGitRepo {
    /// A bare repository beside this one, added as `origin` and pushed to,
    /// with `main` tracking it: a remote that needs no network.
    @discardableResult
    func addBareOrigin() async throws -> URL {
        let bare = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-origin.git")
        try await Self.git(
            ["-c", "init.templateDir=", "init", "-q", "--bare", "-b", "main", bare.path],
            in: url.deletingLastPathComponent()
        )
        try await git(["remote", "add", "origin", bare.path])
        try await git(["push", "-q", "-u", "origin", "main"])
        return bare
    }

    /// Moves `bare`'s `main` one commit on from another clone, as a
    /// teammate's push does, and returns that commit. This repository's
    /// own `main` stays where it was.
    func advance(_ bare: URL) async throws -> String {
        let clone = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-clone")
        try await Self.git(["-c", "init.templateDir=", "clone", "-q", bare.path, clone.path], in: url.deletingLastPathComponent())
        try await Self.configureForTests(clone)
        try await Self.git(["commit", "-q", "--allow-empty", "-m", "teammate"], in: clone)
        try await Self.git(["push", "-q", "origin", "main"], in: clone)
        return try await Self.git(["rev-parse", "HEAD"], in: clone)
    }
}
