// GitStatus.swift
// Limpid — branch / dirty / ahead-behind for a single working tree
// via `git status --porcelain=v2 --branch`. The porcelain v2 header
// contains everything we need so we don't have to chain multiple
// commands:
//
//   # branch.oid abc123…
//   # branch.head main
//   # branch.upstream origin/main
//   # branch.ab +0 -2
//   1 .M N… <path>
//   ? <path>
//
// Any `1 ...`, `2 ...`, `u ...`, or `?` line means the working tree
// is dirty.

import Foundation

struct GitWorktreeStatus: Equatable {
    var branch: String?
    var upstream: String?
    var headSHA: String?
    var ahead: Int
    var behind: Int
    var isDirty: Bool
}

enum GitStatus {
    /// Run `git status` against a worktree path and parse the result.
    /// Returns nil when the path isn't a working tree.
    static func fetch(workingDirectory: URL) async throws -> GitWorktreeStatus? {
        let result = try await GitProcess.run(
            ["status", "--porcelain=v2", "--branch"],
            cwd: workingDirectory
        )
        guard result.succeeded else { return nil }
        return parse(result.stdout)
    }

    /// Parse porcelain-v2 status output. Returns a status struct even
    /// when there are no header lines; fields just stay at their
    /// defaults.
    static func parse(_ porcelain: String) -> GitWorktreeStatus {
        var branch: String?
        var upstream: String?
        var head: String?
        var ahead = 0
        var behind = 0
        var dirty = false

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.oid ") {
                let oid = String(line.dropFirst("# branch.oid ".count))
                // Detached HEAD reports `(detached)` here; leave head
                // nil in that case so callers know.
                if oid != "(initial)", oid != "(detached)" {
                    head = oid
                }
            } else if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                if name != "(detached)" {
                    branch = name
                }
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let pair = String(line.dropFirst("# branch.ab ".count))
                // Format: "+N -N"
                let parts = pair.split(separator: " ")
                if parts.count == 2 {
                    if let a = Int(parts[0].dropFirst()) { ahead = a }
                    if let b = Int(parts[1].dropFirst()) { behind = b }
                }
            } else if line.hasPrefix("1 ")
                || line.hasPrefix("2 ")
                || line.hasPrefix("u ")
                || line.hasPrefix("? ")
            {
                dirty = true
            }
        }
        return GitWorktreeStatus(
            branch: branch,
            upstream: upstream,
            headSHA: head,
            ahead: ahead,
            behind: behind,
            isDirty: dirty
        )
    }
}
